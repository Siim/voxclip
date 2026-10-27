import Testing

/// Pipeline tests that generate, export or play real media run one at a time. Each export holds a
/// hardware encoder session, and CLI tests block a cooperative thread until their subprocess exits;
/// dozens at once starved the three-core CI runner. Each test keeps its own time limit, which starts
/// when the test does, not while it waits for its turn.
@Suite(.serialized) struct HeavyMediaTests {}
