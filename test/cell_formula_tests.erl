-module(cell_formula_tests).
-include_lib("eunit/include/eunit.hrl").

p(S) ->
    {ok, Ast} = cell_formula:parse(S),
    Ast.

r(C, R) -> {ref, C, R, false, false}.

precedence_test_() ->
    [?_assertEqual({binop, '+', {num, 1.0}, {binop, '*', {num, 2.0}, {num, 3.0}}}, p("1+2*3")),
     ?_assertEqual({binop, '-', {binop, '-', {num, 1.0}, {num, 2.0}}, {num, 3.0}}, p("1-2-3")),
     %% unary minus binds tighter than ^, as in spreadsheets
     ?_assertEqual({binop, '^', {neg, {num, 2.0}}, {num, 2.0}}, p("-2^2")),
     ?_assertEqual({binop, '^', {binop, '^', {num, 2.0}, {num, 3.0}}, {num, 2.0}}, p("2^3^2")),
     ?_assertEqual({neg, {pct, {num, 5.0}}}, p("-5%")),
     ?_assertEqual({binop, '=', {binop, '&', {str, <<"a">>}, {str, <<"b">>}}, {str, <<"ab">>}},
                   p("\"a\"&\"b\"=\"ab\"")),
     ?_assertEqual({binop, '&', {num, 1.0}, {binop, '+', {num, 2.0}, {num, 3.0}}}, p("1&2+3")),
     ?_assertEqual({binop, '*', {binop, '+', {num, 1.0}, {num, 2.0}}, {num, 3.0}}, p("(1+2)*3")),
     ?_assertEqual({num, 4.0}, p("+4")),
     ?_assertEqual({binop, '<=', r(1, 1), {num, 3.0}}, p(" A1 <= 3 "))].

atoms_test_() ->
    [?_assertEqual({num, 0.5}, p(".5")),
     ?_assertEqual({num, 1500.0}, p("1.5e3")),
     ?_assertEqual({num, 2.0}, p("2.")),
     ?_assertEqual({str, <<"say \"hi\"">>}, p("\"say \"\"hi\"\"\"")),
     ?_assertEqual({bool, true}, p("true")),
     ?_assertEqual({err, div0}, p("#DIV/0!")),
     ?_assertEqual({ref, 2, 3, true, false}, p("$b3")),
     ?_assertEqual({range, r(1, 1), r(2, 10)}, p("A1:B10")),
     ?_assertEqual({name, <<"FOO">>}, p("foo")),
     ?_assertEqual({name, <<"ABCD1">>}, p("ABCD1")),
     ?_assertEqual({call, <<"SUM">>, [{range, r(1, 1), r(1, 3)}, {num, 4.0}]}, p("sum(A1:A3, 4)")),
     ?_assertEqual({call, <<"PI">>, []}, p("PI()")),
     %% identifiers that look like references are still callable
     ?_assertEqual({call, <<"LOG10">>, [{num, 100.0}]}, p("LOG10(100)"))].

errors_test_() ->
    [?_assertMatch({error, "unexpected end of formula"}, cell_formula:parse("1+")),
     ?_assertMatch({error, "empty formula"}, cell_formula:parse("  ")),
     ?_assertMatch({error, _}, cell_formula:parse("(1")),
     ?_assertMatch({error, _}, cell_formula:parse("1 2")),
     ?_assertMatch({error, _}, cell_formula:parse("SUM(1,)")),
     ?_assertMatch({error, _}, cell_formula:parse("\"open")),
     ?_assertMatch({error, "number out of range" ++ _}, cell_formula:parse("1e999")),
     ?_assertMatch({error, _}, cell_formula:parse("A1:"))].

print_test_() ->
    [?_assertEqual(<<"1+2*3">>, cell_formula:to_string(p("1 + 2 * 3"))),
     ?_assertEqual(<<"(1+2)*3">>, cell_formula:to_string(p("((1+2))*3"))),
     ?_assertEqual(<<"1-(2-3)">>, cell_formula:to_string(p("1-(2-3)"))),
     ?_assertEqual(<<"-(2^2)">>, cell_formula:to_string(p("-(2^2)"))),
     ?_assertEqual(<<"SUM($A$1:B2,\"x\"\"y\")">>, cell_formula:to_string(p("sum($A$1:b2, \"x\"\"y\")"))),
     ?_assertEqual(<<"0.1">>, cell_formula:to_string(p("0.1"))),
     ?_assertEqual(<<"1.0e20">>, cell_formula:to_string(p("1e20")))].

refs_test() ->
    ?assertEqual([{1, 1}, {1, 2}, {2, 1}, {2, 2}, {3, 5}],
                 cell_formula:refs(p("SUM(B2:A1) + C5 * A1"))),
    ?assertEqual([], cell_formula:refs(p("1+2"))).

shift_test_() ->
    S = fun(Src, DC, DR) -> cell_formula:to_string(cell_formula:shift(p(Src), DC, DR)) end,
    [?_assertEqual(<<"B3+$A$1+C$1+$A3">>, S("A2+$A$1+B$1+$A2", 1, 1)),
     ?_assertEqual(<<"SUM(B2:C4)">>, S("SUM(A1:B3)", 1, 1)),
     ?_assertEqual(<<"#REF!+1">>, S("A1+1", 0, -1)),
     ?_assertEqual(<<"SUM(#REF!)">>, S("SUM(A1:B2)", -1, 0)),
     ?_assertEqual(<<"$A$1">>, S("$A$1", -5, 9))].

%% Property: printing then parsing gives back the same tree, for
%% thousands of random formulas.
roundtrip_test_() ->
    {timeout, 60,
     fun() ->
             lists:foreach(
               fun(Seed) ->
                       rand:seed(exsss, {Seed, 7, 11}),
                       Ast = gen(4),
                       Src = cell_formula:to_string(Ast),
                       case cell_formula:parse(Src) of
                           {ok, Ast} -> ok;
                           Other -> erlang:error({roundtrip, Ast, Src, Other})
                       end
               end, lists:seq(1, 3000))
     end}.

gen(0) -> leaf();
gen(D) ->
    case rand:uniform(9) of
        1 -> leaf();
        2 -> {neg, gen(D - 1)};
        3 -> {pct, gen(D - 1)};
        4 -> {call, pick([<<"SUM">>, <<"IF">>, <<"MAX">>]),
              [gen(D - 1) || _ <- lists:seq(1, rand:uniform(3) - 1)]};
        _ -> {binop, pick(['=', '<>', '<', '>', '<=', '>=', '&', '+', '-', '*', '/', '^']),
              gen(D - 1), gen(D - 1)}
    end.

leaf() ->
    case rand:uniform(7) of
        1 -> {num, float(rand:uniform(1000) - 1)};
        2 -> {num, rand:uniform() * 100};
        3 -> {str, pick([<<"">>, <<"a b">>, <<"q\"uote">>])};
        4 -> {bool, pick([true, false])};
        5 -> {err, pick([div0, value, ref, name, na, num, cycle])};
        6 -> {range, ref(), ref()};
        7 -> ref()
    end.

ref() -> {ref, rand:uniform(30), rand:uniform(99), pick([true, false]), pick([true, false])}.

pick(L) -> lists:nth(rand:uniform(length(L)), L).
