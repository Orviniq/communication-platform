enum AppEnvironment {
  development,
  production;

  // There is deliberately no `isProduction`. It existed to drive a two-way
  // branch on the application title, and a build that was neither development
  // nor production inherited development's wording from it (ADR-045). Anything
  // user-facing switches over every value, so a build added later can never
  // inherit another build's wording by default.

  String get provisioningPrefix => switch (this) {
    AppEnvironment.development => 'DEVELOPMENT',
    AppEnvironment.production => 'PRODUCTION',
  };
}
