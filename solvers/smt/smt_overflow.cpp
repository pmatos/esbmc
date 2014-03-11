#include "smt_conv.h"

smt_astt 
smt_convt::overflow_arith(const expr2tc &expr)
{
  // If in integer mode, this is completely pointless. Return false.
  if (int_encoding)
    return mk_smt_bool(false);

  const overflow2t &overflow = to_overflow2t(expr);
  const arith_2ops &opers = static_cast<const arith_2ops &>(*overflow.operand);
  constant_int2tc zero(opers.side_1->type, BigInt(0));
  lessthan2tc op1neg(opers.side_1, zero);
  lessthan2tc op2neg(opers.side_2, zero);

  equality2tc op1iszero(opers.side_1, zero);
  equality2tc op2iszero(opers.side_2, zero);
  or2tc containszero(op1iszero, op2iszero);

  // Guess whether we're performing a signed or unsigned comparison.
  bool is_signed = (is_signedbv_type(opers.side_1) ||
                    is_signedbv_type(opers.side_2));

  if (is_add2t(overflow.operand)) {
    if (is_signed) {
      // Three cases; pos/pos, pos/neg, neg/neg, each with their own failure
      // modes.
      // First, if both pos, usual constraint.
      greaterthanequal2tc c1(overflow.operand, zero);

      // If pos/neg, result needs to be in the range posval > x >= negval
      lessthan2tc foo(overflow.operand, opers.side_1);
      lessthanequal2tc bar(opers.side_2, overflow.operand);
      and2tc c2_1(foo, bar);

      // And vice versa for neg/pos
      lessthan2tc oof(overflow.operand, opers.side_2);
      lessthanequal2tc rab(opers.side_1, overflow.operand);
      and2tc c2_2(oof, rab);

      // neg/neg: result should be below 0.
      lessthan2tc c3(overflow.operand, zero);

      // Finally, encode this into a series of implies that must always be true
      or2tc ncase1(op1neg, op2neg);
      not2tc case1(ncase1);
      implies2tc f1(case1, c1);
      
      equality2tc e1(op1neg, false_expr);
      equality2tc e2(op2neg, true_expr);
      and2tc case2_1(e1, e2);
      implies2tc f2(case2_1, c2_1);

      equality2tc e3(op1neg, true_expr);
      equality2tc e4(op2neg, false_expr);
      and2tc case2_2(e3, e4);
      implies2tc f3(case2_2, c2_2);

      and2tc case3(op1neg, op2neg);
      implies2tc f4(case3, c3);

      // Link them up.
      and2tc f5(f1, f2);
      and2tc f6(f3, f4);
      and2tc f7(f5, f6);
      not2tc inv(f7);
      return convert_ast(inv);
    } else {
      // Just ensure the result is >= both operands.
      greaterthanequal2tc ge1(overflow.operand, opers.side_1);
      greaterthanequal2tc ge2(overflow.operand, opers.side_2);
      and2tc res(ge1, ge2);
      not2tc inv(res);
      return convert_ast(inv);
    }
  } else if (is_sub2t(overflow.operand)) {
    if (is_signed) {
      // Same deal as with add. Enumerate the cases.
      // plus/plus, only failure mode is underflowing:
      lessthanequal2tc c1(overflow.operand, opers.side_1);

      // pos/neg, could overflow.
      greaterthan2tc c2(overflow.operand, opers.side_1);

      // neg/pos - already covered by c1

      // neg/neg - impossible to get wrong.

      equality2tc e1(op1neg, false_expr);
      equality2tc e2(op2neg, false_expr);
      equality2tc e3(op1neg, true_expr);
      equality2tc e4(op2neg, true_expr);

      and2tc cond1(e1, e2);
      and2tc cond3(e3, e2);
      or2tc dualcond(cond1, cond3);
      implies2tc f1(dualcond, c1);

      and2tc cond2(e1, e4);
      implies2tc f2(cond2, c2);

      // No encoding for neg/neg on account of how it's impossible to be wrong

      // Combine
      and2tc f3(f1, f2);
      not2tc inv(f3);
      return convert_ast(inv);
    } else {
      // Just ensure the result is >= the operands.
      lessthanequal2tc le1(overflow.operand, opers.side_1);
      lessthanequal2tc le2(overflow.operand, opers.side_2);
      and2tc res(le1, le2);
      not2tc inv(res);
      return convert_ast(inv);
    }
  } else {
    assert(is_mul2t(overflow.operand) && "unexpected overflow_arith operand");

    // Zero extend; multiply; Make a decision based on the top half.
    unsigned int sz = zero->type->get_width();
    smt_sortt boolsort = mk_sort(SMT_SORT_BOOL);
    smt_sortt normalsort = mk_sort(SMT_SORT_BV, sz, false);
    smt_sortt bigsort = mk_sort(SMT_SORT_BV, sz * 2, false);

    // All one bit vector is tricky, might be 64 bits wide for all we know.
    constant_int2tc allonesexpr(zero->type, BigInt((sz == 64)
                                                 ? 0xFFFFFFFFFFFFFFFFULL
                                                 : ((1ULL << sz) - 1)));
    smt_astt allonesvector = convert_ast(allonesexpr);

    smt_astt arg1_ext, arg2_ext;
    if (is_signed) {
      // sign extend top bits.
      arg1_ext = convert_ast(opers.side_1);
      arg1_ext = convert_sign_ext(arg1_ext, bigsort, sz - 1, sz);
      arg2_ext = convert_ast(opers.side_2);
      arg2_ext = convert_sign_ext(arg2_ext, bigsort, sz - 1, sz);
    } else {
      // Zero extend the top parts
      arg1_ext = convert_ast(opers.side_1);
      arg1_ext = convert_zero_ext(arg1_ext, bigsort, sz);
      arg2_ext = convert_ast(opers.side_2);
      arg2_ext = convert_zero_ext(arg2_ext, bigsort, sz);
    }

    smt_astt result = mk_func_app(bigsort, SMT_FUNC_BVMUL, arg1_ext, arg2_ext);

    // Extract top half.
    smt_astt toppart = mk_extract(result, (sz * 2) - 1, sz, normalsort);

    if (is_signed) {
      // It should either be zero or all one's; which depends on what
      // configuration of signs it had. If both pos / both neg, then the top
      // should all be zeros, otherwise all ones. Implement with xor.
      smt_astt op1neg_ast = convert_ast(op1neg);
      smt_astt op2neg_ast = convert_ast(op2neg);
      smt_astt allonescond =
        mk_func_app(boolsort, SMT_FUNC_XOR, op1neg_ast, op2neg_ast);
      smt_astt zerovector = convert_ast(zero);

      smt_astt initial_switch =
        mk_func_app(normalsort, SMT_FUNC_ITE, allonescond,
                    allonesvector, zerovector);

      // either value being zero means the top must be zero.
      smt_astt contains_zero_ast = convert_ast(containszero);
      smt_astt second_switch = mk_func_app(normalsort, SMT_FUNC_ITE,
                                           contains_zero_ast,
                                           zerovector,
                                           initial_switch);

      smt_astt is_eq =
        mk_func_app(boolsort, SMT_FUNC_EQ, second_switch, toppart);
      return mk_func_app(boolsort, SMT_FUNC_NOT, &is_eq, 1);
    } else {
      // It should be zero; if not, overflow
      smt_astt iseq =
        mk_func_app(boolsort, SMT_FUNC_EQ, toppart, convert_ast(zero));
      return mk_func_app(boolsort, SMT_FUNC_NOT, &iseq, 1);
    }
  }

  return NULL;
}

smt_astt
smt_convt::overflow_cast(const expr2tc &expr)
{
  // If in integer mode, this is completely pointless. Return false.
  if (int_encoding)
    return mk_smt_bool(false);

  const overflow_cast2t &ocast = to_overflow_cast2t(expr);
  unsigned int width = ocast.operand->type->get_width();
  unsigned int bits = ocast.bits;
  smt_sortt boolsort = mk_sort(SMT_SORT_BOOL);

  if (ocast.bits >= width || ocast.bits == 0) {
    std::cerr << "SMT conversion: overflow-typecast got wrong number of bits"
              << std::endl;
    abort();
  }

  // Basically: if it's positive in the first place, ensure all the top bits
  // are zero. If neg, then all the top are 1's /and/ the next bit, so that
  // it's considered negative in the next interpretation.

  constant_int2tc zero(ocast.operand->type, BigInt(0));
  lessthan2tc isnegexpr(ocast.operand, zero);
  smt_astt isneg = convert_ast(isnegexpr);
  smt_astt orig_val = convert_ast(ocast.operand);

  // Difference bits
  unsigned int pos_zero_bits = width - bits;
  unsigned int neg_one_bits = (width - bits) + 1;

  smt_sortt pos_zero_bits_sort =
    mk_sort(SMT_SORT_BV, pos_zero_bits, false);
  smt_sortt neg_one_bits_sort =
    mk_sort(SMT_SORT_BV, neg_one_bits, false);

  smt_astt pos_bits = mk_smt_bvint(BigInt(0), false, pos_zero_bits);
  smt_astt neg_bits = mk_smt_bvint(BigInt((1 << neg_one_bits) - 1),
                                         false, neg_one_bits);

  smt_astt pos_sel = mk_extract(orig_val, width - 1,
                                      width - pos_zero_bits,
                                      pos_zero_bits_sort);
  smt_astt neg_sel = mk_extract(orig_val, width - 1,
                                      width - neg_one_bits,
                                      neg_one_bits_sort);

  smt_astt pos_eq = mk_func_app(boolsort, SMT_FUNC_EQ, pos_bits, pos_sel);
  smt_astt neg_eq = mk_func_app(boolsort, SMT_FUNC_EQ, neg_bits, neg_sel);

  // isneg -> neg_eq, !isneg -> pos_eq
  smt_astt notisneg = mk_func_app(boolsort, SMT_FUNC_NOT, &isneg, 1);
  smt_astt c1 = mk_func_app(boolsort, SMT_FUNC_IMPLIES, isneg, neg_eq);
  smt_astt c2 = mk_func_app(boolsort, SMT_FUNC_IMPLIES, notisneg, pos_eq);

  smt_astt nooverflow = mk_func_app(boolsort, SMT_FUNC_AND, c1, c2);
  return mk_func_app(boolsort, SMT_FUNC_NOT, &nooverflow, 1);
}

smt_astt 
smt_convt::overflow_neg(const expr2tc &expr)
{
  // If in integer mode, this is completely pointless. Return false.
  if (int_encoding)
    return mk_smt_bool(false);

  // Single failure mode: MIN_INT can't be neg'd
  const overflow_neg2t &neg = to_overflow_neg2t(expr);
  unsigned int width = neg.operand->type->get_width();

  constant_int2tc min_int(neg.operand->type, BigInt(1 << (width - 1)));
  equality2tc val(neg.operand, min_int);
  return convert_ast(val);
}

