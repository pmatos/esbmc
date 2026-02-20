# Decimal Support for Python Frontend — Design v2

Supersedes: `2026-02-18-decimal-support-design.md` and `2026-02-18-decimal-pr1-plan.md`

## Problem

ESBMC cannot verify Python code that uses `decimal.Decimal`. The goal is full support for CPython's `decimal.Decimal` semantics, including special values (NaN, sNaN, Infinity, -0), exact arithmetic, and IEEE 854-compliant comparisons.

## Key Design Decision: Preprocessor-Time Rewriting

Instead of parsing strings in the model at BMC time, we rewrite `Decimal()` constructor calls at preprocess time using CPython's own `decimal` module. The preprocessor evaluates the constructor argument, extracts the internal representation, and rewrites the call to use a 4-field internal constructor.

Example: `Decimal("10.5")` → preprocessor rewrites to `Decimal(0, 105, -1, 0)`.

This eliminates string parsing from the model entirely.

## Internal Representation

4-field struct:

| Field | Type | Description |
|-------|------|-------------|
| `_sign` | `int` | 0 = positive, 1 = negative |
| `_int` | `int` | Non-negative integer coefficient |
| `_exp` | `int` | Integer exponent (negative = fractional digits) |
| `_is_special` | `int` | 0 = finite, 1 = infinity, 2 = quiet NaN, 3 = signaling NaN |

Value of finite Decimal: `(-1)^_sign * _int * 10^_exp`

Examples:
- `Decimal("3.14")` → `(sign=0, int_val=314, exp=-2, is_special=0)`
- `Decimal("-0")` → `(sign=1, int_val=0, exp=0, is_special=0)`
- `Decimal("Infinity")` → `(sign=0, int_val=0, exp=0, is_special=1)`
- `Decimal("NaN")` → `(sign=0, int_val=0, exp=0, is_special=2)`
- `Decimal("sNaN")` → `(sign=0, int_val=0, exp=0, is_special=3)`

## Model Constraints

- All loops must be bounded (BMC unrolls them)
- Only primitive types (int, bool) and Decimal itself — no strings, no lists
- Forward references use `"Decimal"` in annotations
- Internal helpers prefixed with `_` (e.g., `_decimal_from_int`)
- Division precision hardcoded to 28 (CPython default)

## Architecture

### 1. Preprocessor (`preprocessor.py`)

Tracks `from decimal import Decimal` and `import decimal` imports. Intercepts `Decimal(...)` calls in `visit_Call` and rewrites arguments:

- Evaluates the argument using CPython's `decimal.Decimal` at preprocess time
- Extracts sign, coefficient (digits→integer), exponent, special status via `as_tuple()`
- Handles: `Decimal("3.14")`, `Decimal(42)`, `Decimal(-5)` (UnaryOp AST), `Decimal()`, `Decimal(3.14)`, `Decimal("NaN")`, `Decimal("sNaN")`, `Decimal("Infinity")`

### 2. Model (`models/decimal.py`)

Decimal class with internal 4-arg constructor. Dunder methods handle mixed int/Decimal operations internally via `_decimal_from_int()`.

### 3. Parser (`parser.py`)

Include `_`-prefixed functions from model modules in filtered AST output (needed for `_decimal_from_int`).

### 4. C++ Converter (`python_converter.cpp`)

Generic dunder dispatch for struct types:

- `op_to_dunder(op)`: static map from AST operator names to dunder method names
- `find_dunder_method(class_name, dunder_name)`: symbol lookup via `find_symbol()`
- `dispatch_dunder_operator(op, lhs, rhs)`: resolves LHS type, skips built-in structs (dict, tuple, Optional), calls dunder method with `gen_address_of(lhs)` as self

Inserted in `get_binary_operator_expr()` after membership operators, before array/dict/list handling. Unary operators (`__neg__`, `__abs__`) handled separately in `get_unary_operator_expr()`.

Built-in struct types to skip in dispatch: tags containing `dict_`, `tag-dict`, starting with `tag-Optional_`, starting with `tag-tuple`.

## Comparison Semantics (CPython-exact)

- NaN is unordered: `NaN == NaN` → False, all ordering comparisons with NaN → False
- sNaN triggers conversion to quiet NaN (traps disabled)
- `-0 == +0` → True
- Normalization before comparison: align exponents to compare `1.0` with `1.00`
- Infinities: `+Inf == +Inf` → True, `+Inf > x` → True for all finite x

## Arithmetic Semantics

- Addition/subtraction: align exponents, add/subtract coefficients
- Multiplication: multiply coefficients, add exponents
- Division: scale dividend by 10^28, integer divide, set exponent
- Floor division / modulo: truncation toward zero (not Python floor division)
- NaN propagation: sNaN → quiet NaN conversion, then quiet NaN propagation
- Infinity: `Inf + Inf = Inf`, `Inf - Inf = NaN`, `Inf * 0 = NaN`

## Testing Strategy

### Hypothesis Property Tests (`tests/python-frontend/test_decimal_model.py`)

Property-based tests using Hypothesis to validate model matches CPython semantics. Custom strategy generates `(sign, int_val, exp, is_special)` tuples. Each operation tested: `model_result == cpython_result` with exact equality.

Run: `uv run pytest tests/python-frontend/test_decimal_model.py -v`

### ESBMC Regression Tests (`regression/python/decimal*/`)

Each PR includes pass + fail regression tests. Format: `test.desc` with `CORE`, source file, `--incremental-bmc`, expected output regex.

## PR Structure (5 PRs)

### PR 1: Foundation

**Scope:** Model skeleton + preprocessor rewriting + parser changes + Hypothesis infra

**Files:**
- `src/python-frontend/models/decimal.py` — Decimal class with `__init__`, `_decimal_from_int`
- `src/python-frontend/preprocessor.py` — Decimal() rewriting, import tracking
- `src/python-frontend/parser.py` — `_`-prefixed helper inclusion
- `tests/python-frontend/test_decimal_model.py` — Hypothesis tests for construction
- `pyproject.toml` — hypothesis dev dependency
- `regression/python/decimal/`, `regression/python/decimal_fail/`

**Enables:** `Decimal("3.14")` constructs correctly, fields accessible.

### PR 2: Generic Dunder Dispatch + Equality

**Scope:** C++ dispatch mechanism + `__eq__`, `__ne__`

**Files:**
- `src/python-frontend/python_converter.cpp` — `op_to_dunder()`, `find_dunder_method()`, `dispatch_dunder_operator()`
- `src/python-frontend/python_converter.h` — declarations
- `src/python-frontend/models/decimal.py` — `__eq__`, `__ne__`
- `tests/python-frontend/test_decimal_model.py` — equality property tests
- `regression/python/decimal2/`, `regression/python/decimal2_fail/`

**Enables:** `Decimal("1.0") == Decimal("1.00")`, NaN inequality.

### PR 3: Ordering Comparisons

**Scope:** `__lt__`, `__le__`, `__gt__`, `__ge__`

**Files:**
- `src/python-frontend/models/decimal.py` — 4 comparison methods
- `tests/python-frontend/test_decimal_model.py` — ordering property tests
- `regression/python/decimal3/`, `regression/python/decimal3_fail/`

**Enables:** Full comparison support, NaN unordered, infinity ordering.

### PR 4: Arithmetic

**Scope:** `__add__`, `__sub__`, `__mul__`, `__truediv__`, `__floordiv__`, `__mod__`, `__neg__`, `__abs__`

**Files:**
- `src/python-frontend/models/decimal.py` — 8 operations
- `src/python-frontend/python_converter.cpp` — unary dispatch in `get_unary_operator_expr()`
- `tests/python-frontend/test_decimal_model.py` — arithmetic property tests
- `regression/python/decimal4/`, `regression/python/decimal4_fail/`

**Enables:** Full arithmetic, mixed Decimal/int, NaN propagation, infinity arithmetic.

### PR 5: Utility Methods

**Scope:** `is_nan()`, `is_infinite()`, `is_zero()`, `is_signed()`

**Files:**
- `src/python-frontend/models/decimal.py` — 4 query methods
- `src/python-frontend/python_converter.cpp` — method call dispatch if needed
- `tests/python-frontend/test_decimal_model.py` — utility property tests
- `regression/python/decimal5/`, `regression/python/decimal5_fail/`

**Enables:** Special value classification queries.

## Build and Test

```sh
# Build
ninja -C build

# Reconfigure after adding test dirs
cd build && cmake .

# Run decimal regression tests
PATH="/home/pmatos/dev/esbmc/.venv/bin:$PATH" ctest -R "regression/python/decimal" --output-on-failure -j4

# Run Hypothesis tests
uv run pytest tests/python-frontend/test_decimal_model.py -v

# Run full Python suite (no regressions)
PATH="/home/pmatos/dev/esbmc/.venv/bin:$PATH" ctest -j$(nproc) -L python --timeout 120

# Clean temp dirs
rm -rf /tmp/esbmc-headers-*
```

## Reference Files

- `src/python-frontend/models/decimal.py` — model
- `src/python-frontend/preprocessor.py` — Decimal rewriting
- `src/python-frontend/parser.py` — helper inclusion
- `src/python-frontend/python_converter.cpp` — dunder dispatch (~line 1484: `get_binary_operator_expr()`)
- `src/python-frontend/python_converter.h` — declarations
- `src/python-frontend/symbol_id.cpp` — symbol ID format
- `src/python-frontend/function_call_expr.cpp` — instance method call patterns
