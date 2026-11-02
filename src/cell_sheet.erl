%% @doc A purely functional spreadsheet with incremental recalculation.
%%
%% The sheet keeps, for every formula cell, the set of cells it reads
%% (its precedents) and the reverse index (dependents). Changing cells
%% recalculates only what can be affected: the changed cells and
%% everything that transitively depends on them. Those cells are
%% evaluated in dependency order, found with Tarjan's strongly connected
%% components algorithm, which also detects circular references; every
%% cell on a cycle evaluates to `#CYCLE!'.
-module(cell_sheet).

-export([new/0, set/3, set_many/2, clear/2, get/2, display/2, input/2,
         formula/2, cells/1, positions/1, bounds/1, precedents/2,
         dependents/2, recalc_all/1, copy/3, size/1]).

-export_type([sheet/0, ref/0, change/0]).

-record(cell, {input :: binary(),
               ast :: undefined | cell_formula:ast(),
               value :: cell_value:value()}).

-record(sheet, {cells = #{} :: #{cell_ref:pos() => #cell{}},
                %% pos => sorted list of positions the cell's formula reads
                deps = #{} :: #{cell_ref:pos() => [cell_ref:pos()]},
                %% pos => set of formula cells that read it
                rdeps = #{} :: #{cell_ref:pos() => sets:set(cell_ref:pos())}}).

-opaque sheet() :: #sheet{}.
-type ref() :: cell_ref:pos() | string() | binary().
-type change() :: {cell_ref:pos(), cell_value:value()}.

-spec new() -> sheet().
new() -> #sheet{}.

-spec size(sheet()) -> non_neg_integer().
size(#sheet{cells = Cells}) -> map_size(Cells).

%% @doc Set one cell. Input starting with `=' is a formula; anything else
%% is a literal (number, TRUE/FALSE or text); an empty input clears the
%% cell. Returns the cells whose value changed.
-spec set(sheet(), ref(), iodata()) ->
          {ok, sheet(), [change()]} | {error, term()}.
set(Sheet, Ref, Input) -> set_many(Sheet, [{Ref, Input}]).

-spec clear(sheet(), ref()) -> {ok, sheet(), [change()]} | {error, term()}.
clear(Sheet, Ref) -> set(Sheet, Ref, <<>>).

%% @doc Set several cells atomically: if any input fails to parse,
%% nothing changes. All edits share one recalculation pass.
-spec set_many(sheet(), [{ref(), iodata()}]) ->
          {ok, sheet(), [change()]} | {error, term()}.
set_many(Sheet, Edits) ->
    case prepare(Edits, []) of
        {error, _} = E -> E;
        {ok, Prepared} ->
            Roots = lists:usort([Pos || {Pos, _} <- Prepared]),
            S1 = apply_edits(Sheet, Prepared),
            {S2, Changed} = recalc(S1, Sheet, Roots),
            {ok, S2, Changed}
    end.

prepare([], Acc) -> {ok, lists:reverse(Acc)};
prepare([{Ref, Input0} | Rest], Acc) ->
    case pos(Ref) of
        {ok, Pos} ->
            Input = iolist_to_binary(Input0),
            case classify(Input) of
                {error, Why} -> {error, {syntax, Pos, Why}};
                Cell -> prepare(Rest, [{Pos, Cell} | Acc])
            end;
        error ->
            {error, {bad_ref, Ref}}
    end.

classify(<<>>) -> clear;
classify(<<"=", Src/binary>> = Input) ->
    case cell_formula:parse(Src) of
        {ok, Ast} -> #cell{input = Input, ast = Ast, value = empty};
        {error, Why} -> {error, Why}
    end;
classify(Input) ->
    #cell{input = Input, ast = undefined, value = cell_value:parse_literal(Input)}.

apply_edits(Sheet, Prepared) ->
    lists:foldl(fun({Pos, Cell}, S) -> put_cell(S, Pos, Cell) end, Sheet, Prepared).

put_cell(#sheet{cells = Cells} = S0, Pos, Cell) ->
    New = case Cell of
              #cell{ast = undefined} -> [];
              #cell{ast = Ast} -> cell_formula:refs(Ast);
              clear -> []
          end,
    S1 = relink(S0, Pos, New),
    case Cell of
        clear -> S1#sheet{cells = maps:remove(Pos, Cells)};
        _ -> S1#sheet{cells = Cells#{Pos => Cell}}
    end.

%% Replace the precedent list of Pos, keeping the reverse index in step.
relink(#sheet{deps = Deps, rdeps = RDeps} = S, Pos, New) ->
    Old = maps:get(Pos, Deps, []),
    Removed = ordsets:subtract(Old, New),
    Added = ordsets:subtract(New, Old),
    RDeps1 = lists:foldl(
               fun(P, Acc) ->
                       Set = sets:del_element(Pos, maps:get(P, Acc)),
                       case sets:is_empty(Set) of
                           true -> maps:remove(P, Acc);
                           false -> Acc#{P => Set}
                       end
               end, RDeps, Removed),
    RDeps2 = lists:foldl(
               fun(P, Acc) ->
                       Set = maps:get(P, Acc, sets:new([{version, 2}])),
                       Acc#{P => sets:add_element(Pos, Set)}
               end, RDeps1, Added),
    Deps1 = case New of
                [] -> maps:remove(Pos, Deps);
                _ -> Deps#{Pos => New}
            end,
    S#sheet{deps = Deps1, rdeps = RDeps2}.

%%% Recalculation ----------------------------------------------------------

%% Recalculate Roots and their transitive dependents. Old is the sheet
%% before the edit, used to report which values actually changed.
recalc(Sheet, Old, Roots) ->
    Affected = affected(Sheet, Roots),
    Order = sccs(Sheet, Affected),
    S1 = lists:foldl(fun(Scc, S) -> eval_scc(S, Scc) end, Sheet, Order),
    Changed = [{P, get(S1, P)} || P <- lists:sort(sets:to_list(Affected)),
                                  get(S1, P) =/= get(Old, P)],
    {S1, Changed}.

%% @doc Recalculate every formula from scratch.
-spec recalc_all(sheet()) -> sheet().
recalc_all(#sheet{cells = Cells} = Sheet) ->
    All = sets:from_list(maps:keys(Cells), [{version, 2}]),
    lists:foldl(fun(Scc, S) -> eval_scc(S, Scc) end, Sheet, sccs(Sheet, All)).

affected(#sheet{rdeps = RDeps}, Roots) ->
    walk(Roots, RDeps, sets:new([{version, 2}])).

walk([], _, Seen) -> Seen;
walk([P | Rest], RDeps, Seen) ->
    case sets:is_element(P, Seen) of
        true -> walk(Rest, RDeps, Seen);
        false ->
            Next = case RDeps of
                       #{P := Set} -> sets:to_list(Set);
                       _ -> []
                   end,
            walk(Next ++ Rest, RDeps, sets:add_element(P, Seen))
    end.

eval_scc(#sheet{deps = Deps} = S, [P]) ->
    case lists:member(P, maps:get(P, Deps, [])) of
        true -> set_value(S, P, {error, cycle});
        false -> eval_cell(S, P)
    end;
eval_scc(S, Scc) ->
    lists:foldl(fun(P, Acc) -> set_value(Acc, P, {error, cycle}) end, S, Scc).

eval_cell(#sheet{cells = Cells} = S, P) ->
    case Cells of
        #{P := #cell{ast = undefined}} -> S;
        #{P := #cell{ast = Ast}} ->
            set_value(S, P, cell_eval:eval(Ast, fun(Q) -> get(S, Q) end));
        _ -> S
    end.

set_value(#sheet{cells = Cells} = S, P, V) ->
    case Cells of
        #{P := #cell{ast = undefined}} -> S;
        #{P := Cell} -> S#sheet{cells = Cells#{P := Cell#cell{value = V}}};
        _ -> S
    end.

%% Tarjan's algorithm over the precedent edges, restricted to the
%% affected cells. Components come out precedents-first, which is the
%% evaluation order.
sccs(#sheet{deps = Deps}, Nodes) ->
    Succ = fun(V) -> [W || W <- maps:get(V, Deps, []), sets:is_element(W, Nodes)] end,
    St0 = #{next => 0, index => #{}, low => #{}, stack => [], on => #{}, out => []},
    St = lists:foldl(
           fun(V, St1) ->
                   case maps:is_key(V, maps:get(index, St1)) of
                       true -> St1;
                       false -> connect(V, Succ, St1)
                   end
           end, St0, lists:sort(sets:to_list(Nodes))),
    lists:reverse(maps:get(out, St)).

connect(V, Succ, #{next := N, index := Ix, low := Lo, stack := Stk, on := On} = St0) ->
    St1 = St0#{next := N + 1, index := Ix#{V => N}, low := Lo#{V => N},
               stack := [V | Stk], on := On#{V => true}},
    St2 = lists:foldl(
            fun(W, St) ->
                    case maps:find(W, maps:get(index, St)) of
                        error ->
                            St3 = connect(W, Succ, St),
                            lower(V, maps:get(W, maps:get(low, St3)), St3);
                        {ok, WIx} ->
                            case maps:get(W, maps:get(on, St), false) of
                                true -> lower(V, WIx, St);
                                false -> St
                            end
                    end
            end, St1, Succ(V)),
    #{low := Lo2, index := Ix2} = St2,
    case maps:get(V, Lo2) =:= maps:get(V, Ix2) of
        true -> pop(V, St2, []);
        false -> St2
    end.

lower(V, X, #{low := Lo} = St) ->
    St#{low := Lo#{V := min(maps:get(V, Lo), X)}}.

pop(V, #{stack := [W | Rest], on := On, out := Out} = St, Acc) ->
    St1 = St#{stack := Rest, on := On#{W := false}},
    case W =:= V of
        true -> St1#{out := [[W | Acc] | Out]};
        false -> pop(V, St1, [W | Acc])
    end.

%%% Queries ----------------------------------------------------------------

%% @doc The current value of a cell (`empty' if it was never set).
-spec get(sheet(), ref()) -> cell_value:value().
get(#sheet{cells = Cells}, Ref) ->
    case Cells of
        #{Ref := #cell{value = V}} -> V;
        _ when is_tuple(Ref) -> empty;
        _ ->
            {ok, Pos} = pos(Ref),
            case Cells of
                #{Pos := #cell{value = V}} -> V;
                _ -> empty
            end
    end.

%% @doc The value as the cell would show it.
-spec display(sheet(), ref()) -> binary().
display(Sheet, Ref) -> cell_value:display(get(Sheet, Ref)).

%% @doc What was typed into the cell (`<<>>' if blank).
-spec input(sheet(), ref()) -> binary().
input(#sheet{cells = Cells}, Ref) ->
    {ok, Pos} = pos(Ref),
    case Cells of
        #{Pos := #cell{input = I}} -> I;
        _ -> <<>>
    end.

%% @doc The parsed formula of a cell, if it has one.
-spec formula(sheet(), ref()) -> {ok, cell_formula:ast()} | none.
formula(#sheet{cells = Cells}, Ref) ->
    {ok, Pos} = pos(Ref),
    case Cells of
        #{Pos := #cell{ast = Ast}} when Ast =/= undefined -> {ok, Ast};
        _ -> none
    end.

%% @doc All non-blank cells as `{Pos, Input, Value}', in reading order
%% (row by row, left to right).
-spec cells(sheet()) -> [{cell_ref:pos(), binary(), cell_value:value()}].
cells(#sheet{cells = Cells}) ->
    Sorted = lists:sort([{R, C} || {C, R} <- maps:keys(Cells)]),
    [begin
         #cell{input = I, value = V} = maps:get({C, R}, Cells),
         {{C, R}, I, V}
     end || {R, C} <- Sorted].

-spec positions(sheet()) -> [cell_ref:pos()].
positions(Sheet) -> [P || {P, _, _} <- cells(Sheet)].

%% @doc `{MaxCol, MaxRow}' of the used area, or `{0, 0}' for a blank sheet.
-spec bounds(sheet()) -> {non_neg_integer(), non_neg_integer()}.
bounds(#sheet{cells = Cells}) ->
    maps:fold(fun({C, R}, _, {MC, MR}) -> {max(C, MC), max(R, MR)} end,
              {0, 0}, Cells).

%% @doc Cells the given cell's formula reads directly.
-spec precedents(sheet(), ref()) -> [cell_ref:pos()].
precedents(#sheet{deps = Deps}, Ref) ->
    {ok, Pos} = pos(Ref),
    maps:get(Pos, Deps, []).

%% @doc Formula cells that read the given cell directly.
-spec dependents(sheet(), ref()) -> [cell_ref:pos()].
dependents(#sheet{rdeps = RDeps}, Ref) ->
    {ok, Pos} = pos(Ref),
    case RDeps of
        #{Pos := Set} -> lists:sort(sets:to_list(Set));
        _ -> []
    end.

%% @doc Copy a cell to another position the way paste does: relative
%% references in a formula move with it, absolute ones stay.
-spec copy(sheet(), ref(), ref()) -> {ok, sheet(), [change()]} | {error, term()}.
copy(Sheet, From, To) ->
    {ok, {FC, FR} = FromPos} = pos(From),
    {ok, {TC, TR} = ToPos} = pos(To),
    Input = case formula(Sheet, FromPos) of
                {ok, Ast} ->
                    Shifted = cell_formula:shift(Ast, TC - FC, TR - FR),
                    <<"=", (cell_formula:to_string(Shifted))/binary>>;
                none ->
                    input(Sheet, FromPos)
            end,
    set(Sheet, ToPos, Input).

-spec pos(ref()) -> {ok, cell_ref:pos()} | error.
pos({C, R} = P) when is_integer(C), is_integer(R) ->
    case cell_ref:valid(P) of
        true -> {ok, P};
        false -> error
    end;
pos(Ref) when is_list(Ref); is_binary(Ref) -> cell_ref:parse(Ref);
pos(_) -> error.
