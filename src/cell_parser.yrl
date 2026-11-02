%% Grammar for spreadsheet formulas, with spreadsheet operator precedence:
%% comparison < & < + - < * / < ^ < unary minus < postfix %.

Nonterminals formula expr uminus uplus primary args.
Terminals number string ref ident errlit
          '=' '<>' '<' '>' '<=' '>=' '&' '+' '-' '*' '/' '^' '%'
          '(' ')' ',' ':'.
Rootsymbol formula.

Left  100 '=' '<>' '<' '>' '<=' '>='.
Left  200 '&'.
Left  300 '+' '-'.
Left  400 '*' '/'.
Left  500 '^'.
Unary 600 uminus uplus.
Left  700 '%'.

formula -> expr : '$1'.

expr -> expr '='  expr : bin('=',  '$1', '$3').
expr -> expr '<>' expr : bin('<>', '$1', '$3').
expr -> expr '<'  expr : bin('<',  '$1', '$3').
expr -> expr '>'  expr : bin('>',  '$1', '$3').
expr -> expr '<=' expr : bin('<=', '$1', '$3').
expr -> expr '>=' expr : bin('>=', '$1', '$3').
expr -> expr '&'  expr : bin('&',  '$1', '$3').
expr -> expr '+'  expr : bin('+',  '$1', '$3').
expr -> expr '-'  expr : bin('-',  '$1', '$3').
expr -> expr '*'  expr : bin('*',  '$1', '$3').
expr -> expr '/'  expr : bin('/',  '$1', '$3').
expr -> expr '^'  expr : bin('^',  '$1', '$3').
expr -> expr '%' : {pct, '$1'}.
expr -> uminus : '$1'.
expr -> uplus : '$1'.
expr -> primary : '$1'.

uminus -> '-' expr : {neg, '$2'}.
uplus  -> '+' expr : '$2'.

primary -> number : {num, value('$1')}.
primary -> string : {str, value('$1')}.
primary -> errlit : {err, value('$1')}.
primary -> ref : cell_formula:mk_ref(value('$1')).
primary -> ref ':' ref : cell_formula:mk_range(value('$1'), value('$3')).
primary -> ident : cell_formula:mk_ident(value('$1')).
primary -> ident '(' ')' : {call, fname('$1'), []}.
primary -> ident '(' args ')' : {call, fname('$1'), '$3'}.
primary -> ref '(' ')' : {call, fname('$1'), []}.
primary -> ref '(' args ')' : {call, fname('$1'), '$3'}.
primary -> '(' expr ')' : '$2'.

args -> expr : ['$1'].
args -> expr ',' args : ['$1' | '$3'].

Erlang code.

bin(Op, L, R) -> {binop, Op, L, R}.

value({_, _, V}) -> V.

fname({_, _, Chars}) -> unicode:characters_to_binary(string:uppercase(Chars)).
