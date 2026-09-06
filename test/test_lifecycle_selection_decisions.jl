@testset "lifecycle selection physical differential" begin
    cases = (
        (
            requests = (
                _physical_request(1, 90),
                _physical_request(1, 10),
                _physical_request(2, 30),
            ),
            kinds = Int16[0, 0, 0, 0],
            generations = UInt32[5, 0, 0, 0],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(1, 90; anchor = 1, sites = (8,)),
                _physical_request(2, 10; anchor = 2, sites = (8,)),
            ),
            kinds = Int16[2, 2, 0, 0],
            generations = UInt32[1, 1, 0, 0],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(1, 50; anchor = 1),
                _physical_request(2, 50; anchor = 1),
            ),
            kinds = Int16[2, 0, 0, 0],
            generations = UInt32[1, 0, 0, 0],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(3, 10; anchor = 3, sites = (7,)),
                _physical_request(1, 20; anchor = 1, sites = (7,)),
                _physical_request(2, 30; anchor = 2, sites = (7,)),
            ),
            kinds = Int16[2, 2, 2, 0],
            generations = UInt32[1, 1, 1, 0],
            policy = :reject,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(2, 1; effect = :create, anchor = 0),
                _physical_request(1, 90; effect = :create, anchor = 0),
            ),
            kinds = Int16[2],
            generations = UInt32[1],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(1, 20; effect = :create, anchor = 2),
            ),
            kinds = Int16[2, 0],
            generations = UInt32[1, typemax(UInt32)],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(1, 20; effect = :create, anchor = 1),
            ),
            kinds = Int16[2, 0],
            generations = UInt32[1, typemax(UInt32)],
            policy = :stable_priority,
            relationships = (),
        ),
        (
            requests = (
                _physical_request(
                    3, 100; anchor = 3, source_handle = 7
                ),
                _physical_request(
                    1, 50; anchor = 1, source_handle = 7,
                    relationship = true,
                ),
                _physical_request(
                    2, 50; anchor = 2, relationship = true
                ),
            ),
            kinds = Int16[2, 2, 2],
            generations = UInt32[1, 1, 1],
            policy = :stable_priority,
            relationships = ((1, 2),),
        ),
    )
    for case in cases
        oracle = _physical_selection_oracle(
            case.requests, case.kinds, case.generations, case.policy,
            case.relationships,
        )
        production = _production_selection_snapshot(
            case.requests, case.kinds, case.generations, case.policy,
            case.relationships,
        )
        @test production == oracle
    end
end

@testset "independent lifecycle selection decision oracle" begin
    key(value) = (
        UInt32(value), UInt32(0), UInt32(0), UInt32(0), Int32(value),
        UInt32(1),
    )
    requests = [
        _oracle_request(key(3), 90; effect = :create),
        _oracle_request(key(1), 10; effect = :divide),
        _oracle_request(key(2), 50),
        _oracle_request(key(1), 99; effect = :divide),
    ]
    no_conflicts = falses(4, 4)
    success = _selection_oracle(
        requests,
        no_conflicts,
        Int16[1, 0, 1, 0, 0],
        UInt32[1, 7, 2, 0, 0],
        :stable_priority,
    )
    @test success.status === :success
    @test success.canonical == [2, 3, 1]
    @test success.selected == [2, 3, 1]
    @test success.free_cells == [2, 4, 5]
    @test success.demands == [2, 1]
    @test success.allocations == Dict(2 => 2, 1 => 4)

    dominance = copy(no_conflicts)
    dominance[1, 3] = true
    dominant = _selection_oracle(
        requests, dominance, zeros(Int16, 5), zeros(UInt32, 5),
        :stable_priority,
    )
    @test dominant.status === :success
    @test dominant.selected == [2, 1]

    tied_requests = copy(requests)
    tied_requests[3] = _oracle_request(key(2), 90)
    tied = _selection_oracle(
        tied_requests, dominance, zeros(Int16, 5), zeros(UInt32, 5),
        :stable_priority,
    )
    @test tied.status === :conflict
    @test tied.conflict == (3, 1)

    reject_conflicts = copy(no_conflicts)
    reject_conflicts[1, 3] = true
    reject_conflicts[2, 3] = true
    rejected = _selection_oracle(
        requests, reject_conflicts, zeros(Int16, 5), zeros(UInt32, 5),
        :reject,
    )
    @test rejected.status === :conflict
    @test rejected.conflict == (2, 3)

    capacity = _selection_oracle(
        requests, no_conflicts, Int16[1, 0, 1], UInt32[1, 7, 2],
        :stable_priority,
    )
    @test capacity.status === :capacity

    overflow = _selection_oracle(
        requests,
        no_conflicts,
        Int16[1, 0, 1, 0],
        UInt32[1, typemax(UInt32), 2, 0],
        :stable_priority,
    )
    @test overflow.status === :generation_overflow
    @test overflow.overflow == (1, 2, 2)
end
