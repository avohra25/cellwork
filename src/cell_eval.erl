%% @doc Formula evaluator.
%%
%% `eval(Ast, Lookup)' computes a formula given a function that returns
%% the current value of any cell. Errors are ordinary values that
%% propagate through operators and most functions; IFERROR, ISERROR and
%% friends observe them.
-module(cell_eval).

-export([eval/2, functions/0]).

-type lookup() :: fun((cell_ref:pos()) -> cell_value:value()).
-export_type([lookup/0]).

%% An argument to an aggregate function, tagged by where it came from:
%% values read from cells are filtered, values written directly coerce.
-type arg() :: {cell | direct, cell_value:value()}.

%% @doc Evaluate a formula. A blank result reads as 0, and a bare range
%% outside a function is `#VALUE!'.
-spec eval(cell_formula:ast(), lookup()) -> cell_value:value().
eval(Ast, Get) ->
    case safe(Ast, Get) of
        empty -> 0.0;
        V -> V
    end.

%% @doc Names of the built-in functions.
-spec functions() -> [binary()].
functions() ->
    [<<"ABS">>, <<"AND">>, <<"AVERAGE">>, <<"CONCAT">>, <<"COUNT">>,
     <<"COUNTA">>, <<"COUNTIF">>, <<"IF">>, <<"IFERROR">>, <<"INT">>,
     <<"ISBLANK">>, <<"ISERROR">>, <<"ISNUMBER">>, <<"ISTEXT">>, <<"LEN">>,
     <<"LOWER">>, <<"MAX">>, <<"MIN">>, <<"MOD">>, <<"NOT">>, <<"OR">>,
     <<"POWER">>, <<"PRODUCT">>, <<"ROUND">>, <<"SQRT">>, <<"SUM">>,
     <<"SUMIF">>, <<"TRIM">>, <<"UPPER">>].

%% Evaluate, turning a thrown error into an error value. Blank stays blank.
safe(Ast, Get) ->
    try ev(Ast, Get)
    catch
        throw:{cell_error, K} -> {error, K};
        error:badarith -> {error, num}
    end.

-spec fail(cell_value:error_kind()) -> no_return().
fail(K) -> throw({cell_error, K}).

ok({ok, V}) -> V;
ok({error, K}) -> fail(K).

num(V) -> ok(cell_value:to_number(V)).
text(V) -> ok(cell_value:to_text(V)).
bool(V) -> ok(cell_value:to_bool(V)).

ev({num, F}, _) -> F;
ev({str, S}, _) -> S;
ev({bool, B}, _) -> B;
ev({err, K}, _) -> {error, K};
ev({name, _}, _) -> {error, name};
ev({ref, C, R, _, _}, Get) -> Get({C, R});
ev({range, _, _}, _) -> {error, value};
ev({neg, E}, Get) -> -num(ev(E, Get));
ev({pct, E}, Get) -> num(ev(E, Get)) / 100;
ev({binop, '&', L, R}, Get) ->
    A = text(ev(L, Get)),
    B = text(ev(R, Get)),
    <<A/binary, B/binary>>;
ev({binop, Op, L, R}, Get) when Op =:= '='; Op =:= '<>'; Op =:= '<';
                                Op =:= '>'; Op =:= '<='; Op =:= '>=' ->
    A = scalar(ev(L, Get)),
    B = scalar(ev(R, Get)),
    test(Op, cell_value:compare(A, B));
ev({binop, Op, L, R}, Get) ->
    A = num(ev(L, Get)),
    B = num(ev(R, Get)),
    arith(Op, A, B);
ev({call, Name, Args}, Get) ->
    call(Name, Args, Get).

scalar({error, K}) -> fail(K);
scalar(V) -> V.

test('=', C) -> C =:= eq;
test('<>', C) -> C =/= eq;
test('<', C) -> C =:= lt;
test('>', C) -> C =:= gt;
test('<=', C) -> C =/= gt;
test('>=', C) -> C =/= lt.

arith('+', A, B) -> A + B;
arith('-', A, B) -> A - B;
arith('*', A, B) -> A * B;
arith('/', _, B) when B == 0 -> fail(div0);
arith('/', A, B) -> A / B;
arith('^', A, B) -> power(A, B).

power(A, B) when A == 0, B < 0 -> fail(div0);
power(A, B) when A < 0, B /= trunc(B) -> fail(num);
power(A, B) ->
    try math:pow(A, B)
    catch error:_ -> fail(num)
    end.

%%% Functions --------------------------------------------------------------

%% Lazy functions first: only the needed arguments are evaluated.
call(<<"IF">>, [C, T], Get) -> call(<<"IF">>, [C, T, {bool, false}], Get);
call(<<"IF">>, [C, T, F], Get) ->
    case bool(ev(C, Get)) of
        true -> ev(T, Get);
        false -> ev(F, Get)
    end;
call(<<"IFERROR">>, [E, Alt], Get) ->
    case safe(E, Get) of
        {error, _} -> ev(Alt, Get);
        V -> V
    end;
call(<<"ISERROR">>, [E], Get) -> cell_value:is_error(safe(E, Get));
call(<<"ISBLANK">>, [E], Get) -> safe(E, Get) =:= empty;
call(<<"ISNUMBER">>, [E], Get) -> is_float(safe(E, Get));
call(<<"ISTEXT">>, [E], Get) -> is_binary(safe(E, Get));
%% Aggregates over cells and ranges.
call(<<"SUM">>, Args, Get) ->
    lists:sum([0.0 | numbers(collect(Args, Get))]);
call(<<"PRODUCT">>, Args, Get) ->
    lists:foldl(fun(X, Acc) -> X * Acc end, 1.0, numbers(collect(Args, Get)));
call(<<"AVERAGE">>, Args, Get) ->
    case numbers(collect(Args, Get)) of
        [] -> fail(div0);
        Ns -> lists:sum(Ns) / length(Ns)
    end;
call(<<"MIN">>, Args, Get) -> extreme(fun erlang:min/2, Args, Get);
call(<<"MAX">>, Args, Get) -> extreme(fun erlang:max/2, Args, Get);
call(<<"COUNT">>, Args, Get) ->
    float(length([V || {Src, V} <- collect(Args, Get),
                       is_float(V) orelse
                           (Src =:= direct andalso countable(V))]));
call(<<"COUNTA">>, Args, Get) ->
    float(length([V || {_, V} <- collect(Args, Get), V =/= empty]));
call(<<"AND">>, Args, Get) -> logical(fun lists:all/2, Args, Get);
call(<<"OR">>, Args, Get) -> logical(fun lists:any/2, Args, Get);
call(<<"CONCAT">>, Args, Get) ->
    iolist_to_binary([text(V) || {_, V} <- collect(Args, Get)]);
call(<<"COUNTIF">>, [Range, Crit], Get) ->
    Match = criterion(scalar(ev(Crit, Get))),
    float(length([V || {_, V} <- collect([Range], Get), Match(V)]));
call(<<"SUMIF">>, [Range, Crit], Get) -> call(<<"SUMIF">>, [Range, Crit, Range], Get);
call(<<"SUMIF">>, [Range, Crit, SumRange], Get) ->
    Match = criterion(scalar(ev(Crit, Get))),
    Tests = [V || {_, V} <- collect([Range], Get)],
    Sums = [V || {_, V} <- collect([SumRange], Get)],
    length(Tests) =:= length(Sums) orelse fail(value),
    lists:sum([0.0 | [S || {T, S} <- lists:zip(Tests, Sums), Match(T), is_float(S)]]);
%% Scalar functions.
call(<<"NOT">>, [E], Get) -> not bool(ev(E, Get));
call(<<"ABS">>, [E], Get) -> abs(num(ev(E, Get)));
call(<<"INT">>, [E], Get) -> float(floor(num(ev(E, Get))));
call(<<"SQRT">>, [E], Get) ->
    case num(ev(E, Get)) of
        X when X < 0 -> fail(num);
        X -> math:sqrt(X)
    end;
call(<<"POWER">>, [A, B], Get) -> power(num(ev(A, Get)), num(ev(B, Get)));
call(<<"MOD">>, [A, B], Get) ->
    X = num(ev(A, Get)),
    case num(ev(B, Get)) of
        Y when Y == 0 -> fail(div0);
        Y -> X - Y * floor(X / Y)
    end;
call(<<"ROUND">>, [E], Get) -> call(<<"ROUND">>, [E, {num, 0.0}], Get);
call(<<"ROUND">>, [E, D], Get) ->
    X = num(ev(E, Get)),
    Scale = math:pow(10, trunc(num(ev(D, Get)))),
    Sign = case X < 0 of true -> -1; false -> 1 end,
    Sign * floor(abs(X) * Scale + 0.5) / Scale;
call(<<"LEN">>, [E], Get) -> float(string:length(text(ev(E, Get))));
call(<<"UPPER">>, [E], Get) -> string:uppercase(text(ev(E, Get)));
call(<<"LOWER">>, [E], Get) -> string:lowercase(text(ev(E, Get)));
call(<<"TRIM">>, [E], Get) ->
    Words = string:lexemes(text(ev(E, Get)), " "),
    iolist_to_binary(lists:join(" ", Words));
call(Name, _Args, _Get) ->
    case lists:member(Name, functions()) of
        true -> fail(value);   % known function, wrong number of arguments
        false -> fail(name)
    end.

%% Expand arguments: ranges and plain references yield `cell' values,
%% anything else is evaluated and yields a `direct' value.
-spec collect([cell_formula:ast()], lookup()) -> [arg()].
collect(Args, Get) -> lists:flatmap(fun(A) -> collect1(A, Get) end, Args).

collect1({range, {ref, C1, R1, _, _}, {ref, C2, R2, _, _}}, Get) ->
    {{CA, RA}, {CB, RB}} = cell_ref:normalize_range({C1, R1}, {C2, R2}),
    [{cell, Get({C, R})} || R <- lists:seq(RA, RB), C <- lists:seq(CA, CB)];
collect1({ref, C, R, _, _}, Get) -> [{cell, Get({C, R})}];
collect1(E, Get) -> [{direct, ev(E, Get)}].

%% Numbers for SUM-like functions: cell values that are not numbers are
%% skipped, direct arguments are coerced, errors propagate.
numbers(Args) ->
    lists:filtermap(
      fun({_, {error, K}}) -> fail(K);
         ({cell, V}) -> case is_float(V) of true -> {true, V}; false -> false end;
         ({direct, V}) -> {true, num(V)}
      end, Args).

countable(V) -> element(1, cell_value:to_number(V)) =:= ok andalso V =/= empty.

extreme(F, Args, Get) ->
    case numbers(collect(Args, Get)) of
        [] -> 0.0;
        [N | Ns] -> lists:foldl(F, N, Ns)
    end.

logical(Quant, Args, Get) ->
    Bools = lists:filtermap(
              fun({_, {error, K}}) -> fail(K);
                 ({cell, V}) when is_boolean(V) -> {true, V};
                 ({cell, V}) when is_float(V) -> {true, V /= 0};
                 ({cell, _}) -> false;
                 ({direct, V}) -> {true, bool(V)}
              end, collect(Args, Get)),
    Bools =/= [] orelse fail(value),
    Quant(fun(B) -> B end, Bools).

%% Build a predicate from a COUNTIF/SUMIF criterion such as 3, ">=10",
%% "<>done" or "a*" (with * and ? wildcards).
criterion(F) when is_float(F) -> fun(V) -> V == F andalso is_float(V) end;
criterion(B) when is_boolean(B) -> fun(V) -> V =:= B end;
criterion(empty) -> fun(V) -> V =:= empty end;
criterion(T) when is_binary(T) ->
    {Op, Operand} = split_op(T),
    case cell_value:parse_number(Operand) of
        {ok, N} ->
            fun(V) -> is_float(V) andalso test(Op, cell_value:compare(V, N)) end;
        error when Op =:= '=' ->
            Re = glob(Operand),
            fun(V) -> is_binary(V) andalso re:run(V, Re) =/= nomatch end;
        error when Op =:= '<>' ->
            Re = glob(Operand),
            fun(V) -> not (is_binary(V) andalso re:run(V, Re) =/= nomatch) end;
        error ->
            fun(V) -> is_binary(V) andalso test(Op, cell_value:compare(V, Operand)) end
    end.

split_op(<<"<>", R/binary>>) -> {'<>', R};
split_op(<<"<=", R/binary>>) -> {'<=', R};
split_op(<<">=", R/binary>>) -> {'>=', R};
split_op(<<"<", R/binary>>) -> {'<', R};
split_op(<<">", R/binary>>) -> {'>', R};
split_op(<<"=", R/binary>>) -> {'=', R};
split_op(R) -> {'=', R}.

glob(Pattern) ->
    Parts = [case C of
                 $* -> ".*";
                 $? -> ".";
                 _ -> re_escape(C)
             end || C <- unicode:characters_to_list(Pattern)],
    {ok, Re} = re:compile(["^", Parts, "$"], [caseless, unicode]),
    Re.

re_escape(C) ->
    case lists:member(C, "\\^$.|?*+()[]{}") of
        true -> [$\\, C];
        false -> [C]
    end.
