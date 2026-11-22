require 'digest'
require 'json'
require 'open3'
require 'socket'
require 'tmpdir'
require 'yaml'

# A local registry with the OCI referrers API, so an upstream digest tag can share
# a name with the OCI layout's fallback referrer tag, as Hummingbird's do.
ZOT_URL = 'https://github.com/project-zot/zot/releases/download/v2.1.23/zot-linux-amd64-minimal'.freeze
ZOT_SHA256 = '8a6e77686bc0e7751766c49828cff6c66b115c854d350c9d936b855463f6c973'.freeze

workflow = YAML.safe_load_file('.github/workflows/mirror.yml')
install, mirror = workflow.fetch('jobs').fetch('mirror').fetch('steps').map { |s| s.fetch('run') }
bash = %w[bash -euo pipefail -c]

# Map the real copy step's refs to the local registry and a disposable OCI layout.
# No network registry or token is needed.
local = <<~'BASH'
  date() { echo 20261122; }
  regctl() {
    if [[ $1 == registry ]]; then
      [[ $(< /dev/stdin) == fixture ]]
      return
    fi
    local args=() arg
    for arg; do
      case "$arg" in
        "$SOURCE") arg="$FIXTURE_REPO:latest" ;;
        "${SOURCE%:*}@"*) arg="$FIXTURE_REPO@${arg##*@}" ;;
        "ghcr.io/cgwalters-forge/$PACKAGE@"*) arg="$FIXTURE_DEST@${arg##*@}" ;;
        "ghcr.io/cgwalters-forge/$PACKAGE:"*.attachment.* | "ghcr.io/cgwalters-forge/$PACKAGE:"*.referrers.*)
          [[ ${FAIL_ARCHIVE:-} != 1 ]] || return 1
          arg="$FIXTURE_DEST:${arg##*:}" ;;
        "ghcr.io/cgwalters-forge/$PACKAGE:$TAG")
          if [[ -n ${PROMOTION_LOG:-} ]]; then echo attempted > "$PROMOTION_LOG"; fi
          arg="$FIXTURE_DEST:$TAG" ;;
        "ghcr.io/cgwalters-forge/$PACKAGE:"*) arg="$FIXTURE_DEST:${arg##*:}" ;;
        *) [[ $arg != *.io/* ]] || return 1 ;;
      esac
      args+=("$arg")
    done
    "$REGCTL_BIN" "${args[@]}"
  }
BASH

Dir.mktmpdir do |tmp|
  path = "#{tmp}/regctl"
  system({ 'RUNNER_TEMP' => tmp, 'GITHUB_PATH' => "#{tmp}/path" }, *bash, install, exception: true)
  zot = "#{tmp}/zot"
  system('curl', '--fail', '--silent', '--show-error', '--location', '--retry', '3', '-o', zot, ZOT_URL, exception: true)
  abort 'Wrong zot checksum' unless Digest::SHA256.file(zot).hexdigest == ZOT_SHA256
  File.chmod(0o700, zot)
  port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
  File.write("#{tmp}/zot.json", JSON.generate(storage: { rootDirectory: "#{tmp}/zot-data" },
                                              http: { address: '127.0.0.1', port: port.to_s }, log: { level: 'error' }))
  server = spawn(zot, 'serve', "#{tmp}/zot.json", out: "#{tmp}/zot.log", err: "#{tmp}/zot.log")
  begin
    # The workflow logs in with this config; the fixture reuses it for plain HTTP.
    config = { 'REGCTL_CONFIG' => "#{tmp}/mirror-auth.json" }
    regctl = lambda do |*args, stdin: ''|
      stdout, status = Open3.capture2(config, path, *args, stdin_data: stdin)
      abort "regctl #{args.join(' ')} failed: #{status}" unless status.success?
      stdout.chomp
    end
    regctl.call('registry', 'set', '--tls', 'disabled', "localhost:#{port}")
    50.times do
      break if system('curl', '--silent', '--fail', '-o', '/dev/null', "http://localhost:#{port}/v2/")
      sleep 0.1
    end

    upstream = "localhost:#{port}/os-minimal"
    build = "ocidir://#{tmp}/build"
    dest = "ocidir://#{tmp}/mirror"
    # The registry rejects images without layers.
    push_image = lambda do |tag, platform, content|
      File.write("#{tmp}/layer", content)
      system('tar', '-C', tmp, '-cf', "#{tmp}/layer.tar", 'layer', exception: true)
      regctl.call('image', 'create', '--platform', platform, "#{build}:base")
      regctl.call('image', 'mod', "#{build}:base", '--layer-add', "tar=#{tmp}/layer.tar", '--create', tag)
      regctl.call('image', 'copy', "#{build}:#{tag}", "#{upstream}:#{tag}")
      regctl.call('image', 'digest', "#{upstream}:#{tag}")
    end
    digest_tag = ->(digest) { digest.tr(':', '-') }
    referrers = lambda do |ref|
      regctl.call('artifact', 'list', '--format', '{{range .Descriptors}}{{println .Digest}}{{end}}', ref).lines.map(&:chomp).sort
    end
    archived_referrers = lambda do |ref|
      JSON.parse(regctl.call('manifest', 'get', '--format', 'raw-body', ref)).fetch('manifests').map { |d| d.fetch('digest') }.sort
    end
    archive = ->(dated, kind, tag) { "#{dest}:#{dated}.#{kind}.#{Digest::SHA256.hexdigest(tag)}" }

    env = { 'SOURCE' => 'quay.io/hummingbird-community/os-minimal:latest', 'PACKAGE' => 'os-minimal', 'TAG' => 'latest',
            'RUNNER_TEMP' => tmp, 'REGISTRY_TOKEN' => 'fixture', 'GITHUB_ACTOR' => 'fixture',
            'GITHUB_RUN_NUMBER' => '12', 'GITHUB_RUN_ATTEMPT' => '2', 'REGCTL_BIN' => path,
            'FIXTURE_REPO' => upstream, 'FIXTURE_DEST' => dest }
    # Each run changes the amd64 image, and so the index, but re-signs the unchanged arm64 image.
    snapshots = %w[2 3].to_h do |attempt|
      content = "fixture #{attempt}"
      amd64 = push_image.call('amd64', 'linux/amd64', content)
      arm64 = push_image.call('arm64', 'linux/arm64', 'arm64')
      regctl.call('index', 'create', '--ref', "#{upstream}:amd64", '--ref', "#{upstream}:arm64", "#{upstream}:latest")
      index = regctl.call('image', 'digest', "#{upstream}:latest")
      # Hummingbird tags its arm64 image with a bare digest alias beside its OCI referrers.
      alias_tag = digest_tag.call(arm64)
      regctl.call('image', 'copy', "#{upstream}:arm64", "#{upstream}:#{alias_tag}")
      signed = ["#{digest_tag.call(index)}.att", "#{alias_tag}.sig"]
      signed.each do |tag|
        regctl.call('artifact', 'put', '--artifact-type', 'application/vnd.dsse.envelope.v1+json', "#{upstream}:#{tag}", stdin: content)
      end
      [index, arm64].each do |subject|
        regctl.call('artifact', 'put', '--artifact-type', 'application/vnd.dev.cosign.simplesigning.v1+json',
                    '--subject', "#{upstream}@#{subject}", stdin: content)
      end

      dated = "latest.20261122.12.#{attempt}"
      system(env.merge('GITHUB_RUN_ATTEMPT' => attempt), *bash, local + mirror, exception: true)
      legacy = [*signed, alias_tag].to_h { |tag| [tag, regctl.call('image', 'digest', "#{upstream}:#{tag}")] }
      refs = [index, arm64].to_h { |subject| [digest_tag.call(subject), referrers.call("#{upstream}@#{subject}")] }
      [dated, { content:, signed:, legacy:, refs:, index:, platforms: [amd64, arm64] }]
    end

    snapshots.each do |dated, s|
      s[:legacy].each do |tag, digest|
        ref = archive.call(dated, 'attachment', tag)
        abort "Wrong attachment manifest for #{dated}: #{tag}" unless regctl.call('image', 'digest', ref) == digest
        abort "Wrong attachment contents for #{dated}: #{tag}" if s[:signed].include?(tag) && regctl.call('artifact', 'get', ref) != s[:content]
      end
      s[:refs].each do |subject_tag, expected|
        abort "Missing OCI referrers for #{dated}: #{subject_tag}" if expected.empty?
        abort "Wrong OCI referrers for #{dated}: #{subject_tag}" unless archived_referrers.call(archive.call(dated, 'referrers', subject_tag)) == expected
        expected.each { |digest| regctl.call('manifest', 'get', "#{dest}@#{digest}") }
      end
      abort "Wrong digest for #{dated}" unless regctl.call('image', 'digest', "#{dest}:#{dated}") == s[:index]
      s[:platforms].each { |digest| regctl.call('manifest', 'get', "#{dest}@#{digest}") }
    end
    abort 'Snapshots share an image digest' unless snapshots.values.map { |s| s[:index] }.uniq.size == 2
    abort 'Moving tag did not advance' unless regctl.call('image', 'digest', "#{dest}:latest") == snapshots.values.last[:index]
    shared = snapshots.values.flat_map { |s| s[:signed] }
    abort 'Shared legacy digest tags were published' unless (regctl.call('tag', 'ls', dest).lines.map(&:chomp) & shared).empty?

    promotion_log = "#{tmp}/promotion"
    failed = env.merge('GITHUB_RUN_ATTEMPT' => '4', 'FAIL_ARCHIVE' => '1', 'PROMOTION_LOG' => promotion_log)
    _, _, status = Open3.capture3(failed, *bash, local + mirror)
    abort 'Incomplete attachment archive did not fail' if status.success?
    abort 'Incomplete snapshot was published' if regctl.call('tag', 'ls', dest).lines.map(&:chomp).include?('latest.20261122.12.4')
    abort 'Failed snapshot attempted promotion' if File.exist?(promotion_log)
  ensure
    Process.kill('TERM', server)
    Process.wait(server)
  end
end
