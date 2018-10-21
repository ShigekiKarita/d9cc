/// 中間表現。レジスタは無限にあるものとして、レジスタの使い回しをしないコードを生成する
module ir;

import std.algorithm : among;
import std.stdio : stderr;
import std.format : format;

import parser;
import util;

// 5+20-4 -> 
// [IR(IMM, 0, 5), a = 5
// IR(IMM, 1, 20), b = 20
// IR(ADD, 0, 1), a += b
// IR(KILL, 1, 0), free(b)
// IR(IMM, 2, 4), c = 4
// IR(SUB, 0, 2), a -= c
// IR(KILL, 2, 0), free(c)
// IR(RETURN, 0, 0)] ret

public:

enum IRType
{
    IMM, // IMmediate Move (即値move) の略? 
    MOV,
    RETURN,
    KILL, // lhsに指定されたレジスタを解放する
    NOP,
    LOAD,
    STORE,
    ADD_IMM, // 即値add
    LABEL,
    UNLESS,
    JMP,
    CALL,
    ADD = '+',
    SUB = '-',
    MUL = '*',
    DIV = '/',
}

enum IRInfo
{
    NOARG,
    REG,
    LABEL,
    REG_REG,
    REG_IMM,
    REG_LABEL,
    CALL,
}

struct IR
{
    IRType op;
    long lhs;
    long rhs;

    // 関数呼び出し
    string name;
    long[] args;

    IRInfo getInfo()
    {
        switch (this.op)
        {
        case IRType.MOV:
        case IRType.ADD:
        case IRType.SUB:
        case IRType.MUL:
        case IRType.DIV:
        case IRType.LOAD:
        case IRType.STORE:
            return IRInfo.REG_REG;
        case IRType.IMM:
        case IRType.ADD_IMM:
            return IRInfo.REG_IMM;
        case IRType.RETURN:
        case IRType.KILL:
            return IRInfo.REG;
        case IRType.LABEL:
        case IRType.JMP:
            return IRInfo.LABEL;
        case IRType.UNLESS:
            return IRInfo.REG_LABEL;
        case IRType.CALL:
            return IRInfo.CALL;
        case IRType.NOP:
            return IRInfo.NOARG;
        default:
            assert(0);
        }
    }

    // -dump-irオプション用
    string toString()
    {
        switch (this.getInfo())
        {
        case IRInfo.REG_REG:
            return format("%s\tr%d\tr%d", this.op, this.lhs, this.rhs);
        case IRInfo.REG_IMM:
            return format("%s\tr%d\t%d", this.op, this.lhs, this.rhs);
        case IRInfo.REG:
            return format("%s\tr%d", this.op, this.lhs);
        case IRInfo.LABEL:
            return format(".L%s:", this.lhs);
        case IRInfo.REG_LABEL:
            return format("%s\tr%d\t.L%s", this.op, this.lhs, this.rhs);
        case IRInfo.NOARG:
            return format("%s", this.op);
        case IRInfo.CALL:
            string s = format("r%d = %s(", this.lhs, this.name);
            foreach (arg; this.args)
                s ~= format("\tr%d", arg);
            s ~= ")";
            return s;
        default:
            assert(0);
        }
    }
}

struct Function
{
    string name;
    long[] args;
    IR[] irs;
    size_t stacksize;
}

Function[] genIR(Node[] node)
{
    Function[] result;
    foreach (n; node)
    {
        assert(n.type == NodeType.FUNCTION);
        size_t regno = 1; // 0番はベースレジスタとして予約
        size_t label;
        size_t stacksize;
        long[string] vars;
        IR[] code;

        code ~= genStatement(regno, stacksize, label, vars, n.function_body);

        Function fn;
        fn.name = n.name;
        fn.irs = code;
        fn.stacksize = stacksize;
        result ~= fn;
    }
    return result;
}

private:

IR[] genStatement(ref size_t regno, ref size_t stacksize, ref size_t label,
        ref long[string] vars, Node* node)
{
    IR[] result;
    if (node.type == NodeType.IF)
    {
        long r = genExpression(result, regno, stacksize, label, vars, node.cond);
        long l_then_end = label;
        label++;
        result ~= IR(IRType.UNLESS, r, l_then_end);
        result ~= IR(IRType.KILL, r, -1);
        result ~= genStatement(regno, stacksize, label, vars, node.then);

        if (!(node.els))
        {
            result ~= IR(IRType.LABEL, l_then_end, -1);
            return result;
        }

        long l_else_end = label;
        result ~= IR(IRType.JMP, l_else_end);
        result ~= IR(IRType.LABEL, l_then_end);
        result ~= genStatement(regno, stacksize, label, vars, node.els);
        result ~= IR(IRType.LABEL, l_else_end);
        return result;
    }
    if (node.type == NodeType.RETURN)
    {
        long r = genExpression(result, regno, stacksize, label, vars, node.expr);
        result ~= IR(IRType.RETURN, r, -1);
        result ~= IR(IRType.KILL, r, -1);
        return result;
    }
    if (node.type == NodeType.EXPRESSION_STATEMENT)
    {
        long r = genExpression(result, regno, stacksize, label, vars, node.expr);
        result ~= IR(IRType.KILL, r, -1);
        return result;
    }
    if (node.type == NodeType.COMPOUND_STATEMENT)
    {
        foreach (n; node.statements)
        {
            result ~= genStatement(regno, stacksize, label, vars, &n);
        }
        return result;
    }
    error("Unknown node: %s", node.type);
    assert(0);
}

long genExpression(ref IR[] ins, ref size_t regno, ref size_t stacksize,
        ref size_t label, ref long[string] vars, Node* node)
{
    if (node.type == NodeType.NUM)
    {
        long r = regno;
        regno++;
        ins ~= IR(IRType.IMM, r, node.val);
        return r;
    }

    if (node.type == NodeType.IDENTIFIER)
    {
        long r = genLval(ins, regno, stacksize, label, vars, node);
        ins ~= IR(IRType.LOAD, r, r);
        return r;
    }

    if (node.type == NodeType.ASSIGN)
    {
        long rhs = genExpression(ins, regno, stacksize, label, vars, node.rhs);
        long lhs = genLval(ins, regno, stacksize, label, vars, node.lhs);
        ins ~= IR(IRType.STORE, lhs, rhs);
        ins ~= IR(IRType.KILL, rhs, -1);
        return lhs;
    }

    if (node.type == NodeType.CALL)
    {
        IR ir;
        ir.op = IRType.CALL;
        foreach (arg; node.args)
            ir.args ~= genExpression(ins, regno, stacksize, label, vars, &arg);

        long r = regno;
        regno++;
        ir.lhs = r;
        ir.name = node.name;
        ins ~= ir;
        foreach (reg; ir.args)
            ins ~= IR(IRType.KILL, reg, -1);
        return r;
    }

    assert(node.type.among!(NodeType.ADD, NodeType.SUB, NodeType.MUL, NodeType.DIV));

    long lhs = genExpression(ins, regno, stacksize, label, vars, node.lhs);
    long rhs = genExpression(ins, regno, stacksize, label, vars, node.rhs);

    ins ~= IR(cast(IRType) node.type, lhs, rhs);
    ins ~= IR(IRType.KILL, rhs, -1);
    return lhs;
}

long genLval(ref IR[] ins, ref size_t regno, ref size_t stacksize, ref size_t label,
        ref long[string] vars, Node* node)
{
    if (node.type != NodeType.IDENTIFIER)
    {
        error("Not an lvalue: ", node);
    }
    if (!(node.name in vars))
    {
        stacksize += 8;
        vars[node.name] = stacksize;
    }

    long r = regno;
    regno++;
    long off = vars[node.name];
    ins ~= IR(IRType.MOV, r, 0);
    ins ~= IR(IRType.ADD_IMM, r, -off);
    return r;
}
