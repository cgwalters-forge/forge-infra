// Self-hosted Renovate for every first-party cgwalters-forge repository
// (the workflow passes the list, from the origin custom property),
// after bootc-dev/infra's renovate-config.js. Each repository is onboarded with
// a config extending the org preset in cgwalters-forge/actions
// (renovate/forge.json), which inherits bootc-dev's shared configuration.
module.exports = {
  onboarding: true,
  onboardingBranch: 'forge-renovate/configure',
  onboardingConfig: {
    $schema: 'https://docs.renovatebot.com/renovate-schema.json',
    extends: ['github>cgwalters-forge/actions//renovate/forge'],
  },
  branchPrefix: 'forge-renovate/',
  platform: 'github',
  // Forks and mirrors follow their upstream; they are not first-party.
  forkProcessing: 'disabled',
  // A dry run unless Octo-STS minted the workflow's token.
  dryRun: process.env.FORGE_RENOVATE_LIVE === 'true' ? null : 'full',
};
