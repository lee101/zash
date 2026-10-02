const std = @import("std");

pub const Word = struct {
    parts: []const Part,
    line: u32 = 0,
};

pub const Part = union(enum) {
    lit: []const u8,
    quoted: []const u8,
    ansi_c: []const u8,
    dquote: []const Part,
    variable: []const u8,
    param: *const ParamExp,
    cmd_subst: *const CmdSubst,
    arith: *const Arith,
    proc_subst: *const ProcSubst,
    tilde: []const u8,
    brace_list: []const Word,
    brace_seq: BraceSeq,
    array_init: []const ArrayElem,
    bad_subst: []const u8,
};

pub const BraceSeq = struct {
    from: []const u8,
    to: []const u8,
    step: ?[]const u8 = null,
    chars: bool = false,
};

pub const ArrayElem = struct {
    key: ?Word = null,
    value: Word,
};

pub const CmdSubst = struct {
    body: List,
    backtick: bool = false,
};

pub const ProcSubst = struct {
    input: bool,
    body: List,
};

pub const Subscript = union(enum) {
    at,
    star,
    index: Word,
};

pub const TrimKind = enum { prefix, prefix_longest, suffix, suffix_longest };
pub const ReplaceKind = enum { first, all, prefix, suffix };

pub const CaseMod = struct {
    upper: bool,
    all: bool,
    pattern: ?Word,
};

pub const ParamOp = union(enum) {
    none,
    use_default: CondWord,
    assign_default: CondWord,
    error_unset: CondWord,
    use_alt: CondWord,
    trim: struct { kind: TrimKind, pattern: Word },
    replace: struct { kind: ReplaceKind, pattern: Word, replacement: ?Word },
    case_mod: CaseMod,
    substring: struct { offset: *const Arith, length: ?*const Arith },
    transform: u8,
    prefix_names: enum { at, star },
};

pub const CondWord = struct {
    colon: bool,
    word: Word,
};

pub const ParamExp = struct {
    name: []const u8,
    subscript: ?Subscript = null,
    indirect: bool = false,
    length: bool = false,
    op: ParamOp = .none,
};

pub const BinOp = enum {
    mul,
    div,
    mod,
    add,
    sub,
    shl,
    shr,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    bit_and,
    bit_xor,
    bit_or,
    log_and,
    log_or,
    pow,
};

pub const UnOp = enum { neg, plus, log_not, bit_not };
pub const IncDec = enum { pre_inc, pre_dec, post_inc, post_dec };

pub const ArithVar = struct {
    name: []const u8,
    index: ?*const Arith = null,
    raw_index: []const u8 = "",
};

pub const Arith = union(enum) {
    num: i64,
    bad_num: []const u8,
    variable: ArithVar,
    expansion: Word,
    unary: struct { op: UnOp, operand: *const Arith },
    incdec: struct { kind: IncDec, target: *const Arith },
    binary: struct { op: BinOp, lhs: *const Arith, rhs: *const Arith },
    assign: struct { op: ?BinOp, target: *const Arith, value: *const Arith },
    ternary: struct { cond: *const Arith, then: *const Arith, otherwise: *const Arith },
    comma: struct { lhs: *const Arith, rhs: *const Arith },
    invalid: struct { expr: []const u8, msg: []const u8 },
};

pub const CondUnary = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    k,
    p,
    r,
    s,
    t,
    u,
    w,
    x,
    G,
    L,
    N,
    O,
    S,
    z,
    n,
    o,
    v,
    R,
};

pub const CondBinary = enum { eq, eq2, ne, match, lt, gt, int_eq, int_ne, int_lt, int_le, int_gt, int_ge, nt, ot, ef };

pub const Cond = union(enum) {
    word: Word,
    unary: struct { op: CondUnary, arg: Word },
    binary: struct { op: CondBinary, lhs: Word, rhs: Word },
    not: *const Cond,
    and_: struct { lhs: *const Cond, rhs: *const Cond },
    or_: struct { lhs: *const Cond, rhs: *const Cond },
    group: *const Cond,
};

pub const RedirOp = enum {
    in,
    out,
    append,
    clobber,
    read_write,
    dup_in,
    dup_out,
    here_str,
    heredoc,
    heredoc_strip,
    out_err,
    append_err,
};

pub const RedirFd = union(enum) {
    none,
    num: u32,
    named: []const u8,
};

pub const Heredoc = struct {
    delimiter: []const u8,
    quoted: bool,
    strip_tabs: bool,
    body: Word = .{ .parts = &.{} },
};

pub const Redirect = struct {
    fd: RedirFd = .none,
    op: RedirOp,
    target: Word,
    heredoc: ?*Heredoc = null,
};

pub const AssignValue = union(enum) {
    scalar: Word,
    array: []const ArrayElem,
};

pub const Assign = struct {
    name: []const u8,
    index: ?Word = null,
    append: bool = false,
    value: AssignValue,
};

pub const Simple = struct {
    assigns: []const Assign,
    words: []const Word,
};

pub const IfClause = struct {
    cond: List,
    body: List,
};

pub const If = struct {
    clauses: []const IfClause,
    else_body: ?List = null,
};

pub const Loop = struct {
    cond: List,
    body: List,
    until: bool = false,
};

pub const ForIn = struct {
    name: []const u8,
    words: ?[]const Word,
    body: List,
};

pub const ArithFor = struct {
    init: ?*const Arith,
    cond: ?*const Arith,
    step: ?*const Arith,
    body: List,
};

pub const CaseTerm = enum { break_, fallthrough, test_next };

pub const CaseClause = struct {
    patterns: []const Word,
    body: List,
    term: CaseTerm,
};

pub const Case = struct {
    word: Word,
    clauses: []const CaseClause,
};

pub const Function = struct {
    name: []const u8,
    body: *const Command,
    keyword: bool = false,
};

pub const Coproc = struct {
    name: ?[]const u8,
    body: *const Command,
};

pub const Body = union(enum) {
    simple: Simple,
    subshell: List,
    group: List,
    if_cmd: If,
    loop: Loop,
    for_in: ForIn,
    arith_for: ArithFor,
    select: ForIn,
    case: Case,
    function: Function,
    cond: *const Cond,
    arith_cmd: *const Arith,
    coproc: Coproc,
};

pub const Command = struct {
    body: Body,
    redirs: []const Redirect = &.{},
    line: u32 = 0,
};

pub const TimeMode = enum { none, time, time_posix };

pub const Pipeline = struct {
    commands: []const Command,
    negate: bool = false,
    time: TimeMode = .none,
    pipe_stderr: []const bool = &.{},
};

pub const LinkOp = enum { and_if, or_if };

pub const AndOrLink = struct {
    op: LinkOp,
    pipeline: Pipeline,
};

pub const AndOr = struct {
    first: Pipeline,
    rest: []const AndOrLink = &.{},
};

pub const Item = struct {
    and_or: AndOr,
    background: bool = false,
    line: u32 = 0,
};

pub const List = struct {
    items: []const Item = &.{},
};

pub fn word_is_plain_lit(w: Word) ?[]const u8 {
    if (w.parts.len == 1) switch (w.parts[0]) {
        .lit => |t| return t,
        else => {},
    };
    return null;
}
