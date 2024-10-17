import Apollo
import ApolloAPI
import ApolloInternalTestHelpers
import Combine
import XCTest

@testable import ApolloPagination

final class GraphQLQueryPagerCoordinatorTests: XCTestCase, CacheDependentTesting {
  private typealias ForwardQuery = MockQuery<Mocks.Hero.FriendsQuery>

  var cacheType: any TestCacheProvider.Type {
    InMemoryTestCacheProvider.self
  }

  var cache: (any NormalizedCache)!
  var server: MockGraphQLServer!
  var client: ApolloClient!
  var cancellables: [AnyCancellable] = []

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    cache = try await makeNormalizedCache()
    let store = ApolloStore(cache: cache)

    server = MockGraphQLServer()
    let networkTransport = MockNetworkTransport(server: server, store: store)

    client = ApolloClient(networkTransport: networkTransport, store: store)
    MockSchemaMetadata.stub_cacheKeyInfoForType_Object(IDCacheKeyProvider.resolver)
  }

  override func tearDownWithError() throws {
    cache = nil
    server = nil
    client = nil
    cancellables.forEach { $0.cancel() }
    cancellables = []

    try super.tearDownWithError()
  }

  private func createForwardPager() -> AsyncGraphQLQueryPagerCoordinator<ForwardQuery, ForwardQuery> {
    let initialQuery = ForwardQuery()
    initialQuery.__variables = ["id": "2001", "first": 2, "after": GraphQLNullable<String>.null]
    return AsyncGraphQLQueryPagerCoordinator<ForwardQuery, ForwardQuery>(
      client: client,
      initialQuery: initialQuery,
      watcherDispatchQueue: .main,
      extractPageInfo: { data in
        switch data {
        case .initial(let data, _), .paginated(let data, _):
          return CursorBasedPagination.Forward(
            hasNext: data.hero.friendsConnection.pageInfo.hasNextPage,
            endCursor: data.hero.friendsConnection.pageInfo.endCursor
          )
        }
      },
      pageResolver: { pageInfo, direction in
        guard direction == .next else { return nil }
        let nextQuery = ForwardQuery()
        nextQuery.__variables = [
          "id": "2001",
          "first": 2,
          "after": pageInfo.endCursor,
        ]
        return nextQuery
      }
    )
  }

  // MARK: - Reset Tests

  @available(iOS 16.0, macOS 13.0, *)
  func test__reset__calls_callback() throws {
    server.customDelay = .milliseconds(1)
    let pager = GraphQLQueryPagerCoordinator(pager: createForwardPager())
    let serverExpectation = Mocks.Hero.FriendsQuery.expectationForFirstPage(server: server)

    pager.fetch()
    wait(for: [serverExpectation], timeout: 1)
    server.customDelay = .milliseconds(200)
    let secondPageExpectation = Mocks.Hero.FriendsQuery.expectationForSecondPage(server: server)
    let callbackExpectation = expectation(description: "Callback")
    pager.loadNext(completion: { _ in
      callbackExpectation.fulfill()
    })
    usleep(50_000)
    pager.reset()
    wait(for: [callbackExpectation, secondPageExpectation], timeout: 1)
  }

  @available(iOS 16.0, macOS 13.0, *)
  func test__reset__calls_callback_manyQueuedRequests() throws {
    server.customDelay = .milliseconds(1)
    let pager = GraphQLQueryPagerCoordinator(pager: createForwardPager())
    let serverExpectation = Mocks.Hero.FriendsQuery.expectationForFirstPage(server: server)
    var results: [Result<PaginationOutput<ForwardQuery, ForwardQuery>, any Error>] = []
    var errors: [PaginationError?] = []

    pager.fetch()
    wait(for: [serverExpectation], timeout: 1)
    server.customDelay = .milliseconds(150)
    pager.subscribe { result in
      results.append(result)
    }
    let secondPageExpectation = Mocks.Hero.FriendsQuery.expectationForSecondPage(server: server)
    pager.loadNext(completion: { error in
      errors.append(error)
    })
    pager.loadNext(completion: { error in
      errors.append(error)
    })
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
        pager.reset()
    }

    wait(for: [secondPageExpectation], timeout: 2)
    XCTAssertEqual(results.count, 1) // once for original fetch
    XCTAssertEqual(errors.count, 2)
    XCTAssertTrue(errors.contains(where: { PaginationError.isCancellation(error: $0) }))
  }

  @available(iOS 16.0, macOS 13.0, *)
  func test__reset__calls_callback_deinit() throws {
    server.customDelay = .milliseconds(1)
    var pager: GraphQLQueryPagerCoordinator! = GraphQLQueryPagerCoordinator(pager: createForwardPager())
    let serverExpectation = Mocks.Hero.FriendsQuery.expectationForFirstPage(server: server)
    var results: [Result<PaginationOutput<ForwardQuery, ForwardQuery>, any Error>] = []
    var errors: [PaginationError?] = []

    pager.subscribe { result in
      results.append(result)
    }
    pager.fetch()
    wait(for: [serverExpectation], timeout: 1)

    server.customDelay = .milliseconds(150)
    let secondPageExpectation = Mocks.Hero.FriendsQuery.expectationForSecondPage(server: server)

    pager.loadNext(completion: { error in
      errors.append(error)
    })

    // Sleep for 50ms make sure that `loadNext` kicked in but the server does not return anything yet.
    usleep(50_000)
    pager = nil

    wait(for: [secondPageExpectation], timeout: 2)
    XCTAssertEqual(results.count, 1) // once for original fetch
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors.contains(where: { PaginationError.isCancellation(error: $0) }))
  }
}
