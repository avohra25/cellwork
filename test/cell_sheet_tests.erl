-module(cell_sheet_tests).
-include_lib("eunit/include/eunit.hrl").

build(Edits) ->
    {ok, S, _} = cell_sheet:set_many(cell_sheet:new(), Edits),
    S.

d(S, Ref) -> cell_sheet:display(S, Ref).

basic_test() ->
    S = build([{"A1", "10"}, {"A2", "=A1*2"}, {"A3", "=SUM(A1:A2)"}, {"B1", "hello"},
               {"B2", "'42"}, {"B3", "true"}]),
    ?assertEqual(<<"20">>, d(S, "A2")),
    ?assertEqual(<<"30">>, d(S, "A3")),
    ?assertEqual(<<"hello">>, d(S, "B1")),
    ?assertEqual(<<"42">>, cell_sheet:get(S, "B2")),          % apostrophe forces text
    ?assertEqual(true, cell_sheet:get(S, "B3")),
    ?assertEqual(empty, cell_sheet:get(S, "Z99")),
    ?assertEqual(<<"=A1*2">>, cell_sheet:input(S, "A2")),
    ?assertEqual({2, 3}, cell_sheet:bounds(S)),
    ?assertEqual(6, cell_sheet:size(S)).

changes_reported_test() ->
    S0 = build([{"A1", "1"}, {"A2", "=A1+1"}, {"A3", "=A2*0"}, {"B1", "=5"}]),
    {ok, S1, Changed} = cell_sheet:set(S0, "A1", "2"),
    %% A3 is recalculated but stays 0, so only A1 and A2 are reported
    ?assertEqual([{{1, 1}, 2.0}, {{1, 2}, 3.0}], Changed),
    ?assertEqual(<<"0">>, d(S1, "A3")),
    {ok, _, []} = cell_sheet:set(S1, "A1", "2").

forward_reference_test() ->
    %% formulas may refer to cells that are filled in later
    {ok, S0, _} = cell_sheet:set(cell_sheet:new(), "A1", "=B1+1"),
    ?assertEqual(<<"1">>, d(S0, "A1")),
    {ok, S1, Changed} = cell_sheet:set(S0, "B1", "41"),
    ?assertEqual([{{1, 1}, 42.0}, {{2, 1}, 41.0}], Changed),
    ?assertEqual(<<"42">>, d(S1, "A1")).

clear_test() ->
    S0 = build([{"A1", "5"}, {"A2", "=A1*3"}]),
    {ok, S1, Changed} = cell_sheet:clear(S0, "A1"),
    ?assertEqual([{{1, 1}, empty}, {{1, 2}, 0.0}], Changed),
    ?assertEqual(1, cell_sheet:size(S1)),
    ?assertEqual([{1, 2}], cell_sheet:dependents(S1, "A1")).

dependency_index_test() ->
    S0 = build([{"A1", "=B1+C1"}, {"A2", "=SUM(B1:B3)"}]),
    ?assertEqual([{2, 1}, {3, 1}], cell_sheet:precedents(S0, "A1")),
    ?assertEqual([{1, 1}, {1, 2}], cell_sheet:dependents(S0, "B1")),
    ?assertEqual([{1, 2}], cell_sheet:dependents(S0, "B3")),
    {ok, S1, _} = cell_sheet:set(S0, "A2", "7"),
    ?assertEqual([{1, 1}], cell_sheet:dependents(S1, "B1")),
    ?assertEqual([], cell_sheet:dependents(S1, "B3")),
    ?assertEqual([], cell_sheet:precedents(S1, "A2")).

cycle_test() ->
    S0 = build([{"A1", "=A3+1"}, {"A2", "=A1+1"}, {"A3", "=A2+1"}, {"B1", "=A1*2"},
                {"C1", "=C1"}, {"D1", "=IFERROR(A1,99)"}]),
    [?assertEqual(<<"#CYCLE!">>, d(S0, R)) || R <- ["A1", "A2", "A3", "C1"]],
    ?assertEqual(<<"#CYCLE!">>, d(S0, "B1")),   % downstream of a cycle
    ?assertEqual(<<"99">>, d(S0, "D1")),
    %% breaking the cycle recalculates every member
    {ok, S1, _} = cell_sheet:set(S0, "A3", "10"),
    ?assertEqual(<<"11">>, d(S1, "A1")),
    ?assertEqual(<<"12">>, d(S1, "A2")),
    ?assertEqual(<<"22">>, d(S1, "B1")),
    ?assertEqual(<<"11">>, d(S1, "D1")).

cycle_through_range_test() ->
    S = build([{"A1", "1"}, {"A2", "2"}, {"A3", "=SUM(A1:A3)"}]),
    ?assertEqual(<<"#CYCLE!">>, d(S, "A3")).

syntax_error_is_atomic_test() ->
    S0 = build([{"A1", "1"}]),
    ?assertMatch({error, {syntax, {2, 1}, _}},
                 cell_sheet:set_many(S0, [{"A1", "2"}, {"B1", "=1+"}])),
    ?assertEqual({error, {bad_ref, "ZZZZ1"}}, cell_sheet:set(S0, "ZZZZ1", "1")),
    ?assertEqual(1.0, cell_sheet:get(S0, "A1")).

copy_test() ->
    S0 = build([{"A1", "1"}, {"A2", "2"}, {"B1", "10"}, {"B2", "20"},
                {"C1", "=A1*$B$1+A$2"}, {"D9", "plain"}]),
    {ok, S1, _} = cell_sheet:copy(S0, "C1", "D2"),
    ?assertEqual(<<"=B2*$B$1+B$2">>, cell_sheet:input(S1, "D2")),
    ?assertEqual(<<"220">>, d(S1, "D2")),
    {ok, S2, _} = cell_sheet:copy(S1, "C1", {3, 1}),
    ?assertEqual(<<"=A1*$B$1+A$2">>, cell_sheet:input(S2, "C1")),
    {ok, S3, _} = cell_sheet:copy(S2, "D2", "A1"),
    ?assertEqual(<<"=#REF!*$B$1+#REF!">>, cell_sheet:input(S3, "A1")),
    ?assertEqual(<<"#REF!">>, d(S3, "A1")),
    {ok, S4, _} = cell_sheet:copy(S3, "D9", "E9"),
    ?assertEqual(<<"plain">>, d(S4, "E9")).

cells_order_test() ->
    S = build([{"B2", "x"}, {"A2", "y"}, {"C1", "z"}]),
    ?assertEqual([{3, 1}, {1, 2}, {2, 2}], cell_sheet:positions(S)).

long_chain_test() ->
    N = 5000,
    Edits = [{"A1", "1"} | [{{1, R}, ["=A", integer_to_list(R - 1), "+1"]} || R <- lists:seq(2, N)]],
    S0 = build(Edits),
    ?assertEqual(float(N), cell_sheet:get(S0, {1, N})),
    {ok, S1, Changed} = cell_sheet:set(S0, "A1", "100"),
    ?assertEqual(N, length(Changed)),
    ?assertEqual(float(N + 99), cell_sheet:get(S1, {1, N})).

%%% Randomized differential tests -----------------------------------------

-define(COLS, 4).
-define(ROWS, 4).

grid() -> [{C, R} || C <- lists:seq(1, ?COLS), R <- lists:seq(1, ?ROWS)].

name({C, R}) -> cell_ref:to_string({C, R}).

rand_pos() -> {rand:uniform(?COLS), rand:uniform(?ROWS)}.

%% Inputs that read only from `Pool'.
rand_input([]) -> integer_to_list(rand:uniform(20) - 5);
rand_input(Pool) ->
    P = fun() -> name(lists:nth(rand:uniform(length(Pool)), Pool)) end,
    case rand:uniform(11) of
        1 -> "";
        2 -> integer_to_list(rand:uniform(20) - 5);
        3 -> "=" ++ P() ++ "+" ++ P();
        4 -> "=" ++ P() ++ "*2-" ++ P();
        5 -> "=" ++ P() ++ "/" ++ P();
        6 -> "=IF(" ++ P() ++ ">3," ++ P() ++ "," ++ P() ++ "-1)";
        7 -> "=IFERROR(" ++ P() ++ "/" ++ P() ++ ",0)";
        8 -> "=SUM(" ++ P() ++ ":" ++ P() ++ ")";
        9 -> "=COUNTIF(" ++ P() ++ ":" ++ P() ++ ",\">2\")";
        10 -> "=MAX(" ++ P() ++ "," ++ P() ++ ")&\"\"";
        11 -> "=" ++ P()
    end.

snapshot(S) -> [{P, cell_sheet:get(S, P)} || P <- grid()].

%% Incremental recalculation after many random edits must agree with a
%% fresh sheet built from the final inputs, and with recalculating
%% everything from scratch. Reported changes must be exactly the cells
%% whose value changed.
incremental_matches_fresh_test_() ->
    {timeout, 120,
     fun() ->
             lists:foreach(fun differential/1, lists:seq(1, 300))
     end}.

differential(Seed) ->
    rand:seed(exsss, {Seed, 3, 5}),
    Final = lists:foldl(
              fun(_, S0) ->
                      Edits = [{rand_pos(), rand_input(grid())}
                               || _ <- lists:seq(1, rand:uniform(2))],
                      {ok, S1, Changed} = cell_sheet:set_many(S0, Edits),
                      Expected = [{P, V} || {{P, V}, {P, V0}} <- lists:zip(snapshot(S1), snapshot(S0)),
                                            V =/= V0],
                      ?assertEqual({Seed, Expected}, {Seed, [C || {P, _} = C <- Changed,
                                                                  lists:member(P, grid())]}),
                      S1
              end, cell_sheet:new(), lists:seq(1, 40)),
    Inputs = [{P, I} || {P, I, _} <- cell_sheet:cells(Final)],
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- Inputs])],
    Fresh = build(Shuffled),
    ?assertEqual({Seed, snapshot(Fresh)}, {Seed, snapshot(Final)}),
    ?assertEqual({Seed, snapshot(Final)}, {Seed, snapshot(cell_sheet:recalc_all(Final))}).

%% On acyclic sheets the engine must agree with a naive recursive
%% evaluator that knows nothing about dependency graphs.
naive_oracle_test_() ->
    {timeout, 120,
     fun() ->
             lists:foreach(fun oracle/1, lists:seq(1, 300))
     end}.

oracle(Seed) ->
    rand:seed(exsss, {Seed, 9, 2}),
    %% cell i may only read cells before it in this random order: acyclic
    Order = [X || {_, X} <- lists:sort([{rand:uniform(), P} || P <- grid()])],
    {Edits, _} = lists:mapfoldl(
                   fun(P, Before) ->
                           Pool = Before,
                           {{P, rand_acyclic(Pool)}, [P | Before]}
                   end, [], Order),
    %% feed edits in a different order than the dependency order
    S = lists:foldl(fun(E, Acc) -> {ok, Acc1, _} = cell_sheet:set_many(Acc, [E]), Acc1 end,
                    cell_sheet:new(), lists:reverse(Edits)),
    Inputs = maps:from_list(Edits),
    Naive = fun Naive(P) ->
                    case maps:get(P, Inputs, "") of
                        "" -> empty;
                        "=" ++ Src ->
                            {ok, Ast} = cell_formula:parse(Src),
                            cell_eval:eval(Ast, Naive);
                        Lit -> cell_value:parse_literal(list_to_binary(Lit))
                    end
            end,
    [?assertEqual({Seed, P, Naive(P)}, {Seed, P, cell_sheet:get(S, P)}) || P <- grid()].


%% Ranges could cover later cells, so the acyclic generator uses only
%% single references.
rand_acyclic([]) -> integer_to_list(rand:uniform(9));
rand_acyclic(Pool) ->
    P = fun() -> name(lists:nth(rand:uniform(length(Pool)), Pool)) end,
    case rand:uniform(6) of
        1 -> integer_to_list(rand:uniform(9));
        2 -> "=" ++ P() ++ "+" ++ P();
        3 -> "=" ++ P() ++ "/" ++ P();
        4 -> "=IF(" ++ P() ++ ">5," ++ P() ++ "," ++ P() ++ "*3)";
        5 -> "=MAX(" ++ P() ++ "," ++ P() ++ ",1)";
        6 -> "=IFERROR(1/(" ++ P() ++ "-" ++ P() ++ "),-1)"
    end.
