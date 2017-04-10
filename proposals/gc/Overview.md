# GC Extension

## Introduction

### Motivation

* Efficient support for high-level languages
  - faster execution
  - smaller deliverables
  - the vast majority of modern languages need it

* Efficient interoperability with embedder heap
  - for example, DOM objects on the web
  - no space leaks from mapping bidirectional tables

* Provide access to industrial-strength GCs
  - at least on the web, VMs already have high performance GCs

* Non-goal: seamless interoperability between multiple languages


### Challenges

* Fast but type-safe
* Lean but sufficiently universal
* Language-independent
* Trade-off triangle between simplicity, expressiveness and performance
* Interaction with threads


### Approach

* Only basic but general structure: tuples (structs) and arrays.
* No heavyweight object model.
* Accept minimal amount of dynamic overhead (checked casts) as price for simplicity/universality.
* Independent from linear memory.
* Pay as you go.
* Avoid generics or other complex type structure if possible.


### Requirements

* Allocation of structures on the heap which are garbage collected.
* Allocation of unstructured byte arrays which are garbage collected.
* Handles to heap values from the embedder, garbage collected.
Constructing closures which are  garbage collected.
Manipulating references to these, as value types.
Forming unions of different types, as value types.
Defining, allocating, and indexing structures as extensions to imported types.
Exceptions
Direct support for strings?


### Efficiency Considerations

Managed Wasm should inherit the efficiency properties of unmanaged Wasm as much as possible, namely:

* all operations are very cheap, ideally constant time,
* structures are contiguous, dense chunks of memory,
* accessing fields are single-indirection loads and stores,
* allocation is fast,
* no implicit boxing operations (i.e. no implicit allocation on the heap),
* primitive values should not need to be boxed to be stored in managed data structures.


## Use Cases

### Tuples and Arrays

* Want to represent first-class tuples/records/structs with static indexing.
* Want to represent arrays with dynamic indexing.
* Possibly want to create arrays with both fixed or dynamic size.

Example (fictional language):
```
type tup = (int, int, bool)
type vec3d = float[3]
type buf = {pos : int, buf : char[]}
```

Needs:

* user-defined structures and arrays as heap objects,
* references to those as first-class values.


### Objects and Method Tables

* Want to represent instances as structures, whose first field is the method table.
* Want to represent method tables themselves as structures, whose fields are function pointers.
* Subtyping is relevant, both on instance types and method table types.

Example (Java-ish):
```
class C {
  int a;
  void f(int i);
  int g();
}
class D extends C {
  double b;
  override int g();
  int h();
}
```

```
(type $f-sig (func (param (ref $C)) (param i32)))   ;; first param is `this`
(type $g-sig (func (param (ref $C)) (result i32)))
(type $h-sig (func (param (ref $D)) (result i32)))

(type $C (struct (ref $C-vt) (mut i32))
(type $C-vt (struct (ref $f-sig) (ref $gh-sig)))    ;; all immutable
(type $D (struct (ref $D-vt) (mut i32) (mut f64)))  ;; subtype of $C
(type $D-vt (struct (extend $C-vt) (ref $g-sig)))   ;; immutable, subtype of $C-vt
```

Needs:

* (structural) subtyping,
* immutable fields (for sound subtyping),
* universal type of references,
* down casts
* dynamic linking might add a whole new dimension.

To emulate the covariance of the `this` parameter, one down cast on `this` is needed in the compilation of each method that overrides a method from a base class.
For example, `D.g`:
```
(func $D.g (param $Cthis (ref $C))
  (local $this (ref $D))
  (set_local $clos (call $outer (f64.const 1)))
  (block $fail (result (ref $D))
    (set_local $this (cast_down (ref $Cthis) (ref $D) $fail (get_local $Cthis)))
    ...
  )
  (unreachable)
)
```


### Closures

* Want to represent closures as pairs of typed function pointers and typed environment record.

Example:
```
function outer(x : f64) : float -> float {
  let a = x + 1
  function inner(y : float) {
    return y + a + x
  }
  return inner
}

function caller() {
  return outer(1)(2)
}
```

```
(type $func-f64-f64 (func (param $env $anyref) (param $y f64) (result f64)))
(type $clos-f64-f64 (struct (field $code (ref $func-f64-f64)) (field $env anyref)))
(type $inner-env (struct (field $x i32) (field $a i32)))

(func $outer (param $x f64) (result (ref $clos-f64-f64))
  (ref_func $inner)
  (get_local $x)
  (f64.add (get_local $x) (f64.const 1))
  (new $inner-env)
  (new $clos-f64-f64)
)

(func $inner (param $anyenv anyref) (param $y f64) (result f64)
  (local $env (ref $inner-env))
  (block $fail (result (ref anyref))
    (set_local $env (cast_down anyref (ref $inner-env) $fail (get_local _$anyenv)))
    (get_local $y)
    (get_field $inner-env $a (get_local $env))
    (f64.add)
    (get_field $inner-env $x (get_local $env))
    (f64.add)
    (return)
  )
  (unreachable)
)

(func $caller (result f64)
  (local $clos (ref $clos-f64-f64))
  (set_local $clos (call $outer (f64.const 1)))
  (call_ref
    (get_field $clos-f64-f64 $env (get_local $clos))
    (f64.const 2)
    (get_field $clos-f64-f64 $code (get_local $clos))
  )
)
```

Needs:
* function pointers
* universal type of references
* down casts

The down cast for the closure environment is necessary because expressing its static type faithfully would require first-class generics and existential types.

An alternative is to provide [primitive support](#closures) for closures.


### Parametric Polymorphism

TODO: via type `anyref` and `intref`


### Type Export/Import

* Want to allow type definitions to be imported from other modules.
* As much as possible of the above constructions should be allowed with abstract types.
* More complicated linking patterns might require user-space linking hooks.
* Possibly: allow abstract type exports (encapsulation)?
* Lots of tricky details here, mostly ignore for now...


## Basic Functionality: Simple aggregates

* Extend the Wasm type section with new constructors for aggregate types.
* Extend the value types with new constructors for references and interior references.
* Aggregate types are not value types, only references to them are.
* References are never null; nullable reference types are separate.


### Structs

*Structure* types define aggregates with heterogeneous fields that are _statically indexed_:
```
(type $time (struct (field i32) (field f64)))
(type $point (struct (field $x f64) (field $y f64) (field $z f64)))
```
Such types can be used by forming *reference types*, which are a new type of value type:
```
(local $var (ref $point))
```

Fields are *accessed* with generic load/store instructions that take a reference to a structure:
```
(func $f (param $p (ref $point))
  (store_field $point $y (get_local $p)
    (load_field $point $x (get_local $p))
  )
)
```
All accesses are type-checked at validation time.

Structures are [allocated](#allocation) with `new` instructions that take initialization values for each field.
The operator yields a reference to the respective type:
```
(func $g
  (call $g (new_struct $point (i32.const 1) (i32.const 2) (i32.const 3)))
)
```
Structures are garbage-collected.


### Arrays

*Array* types define aggregates with _homogeneous elements_ that are _dynamically indexed_:
```
(type $vector (array f64))
(type $matrix (array (type $vector)))
```
Such types again can be used by forming reference types.
For now, we assume that all array types have dynamic ([flexible](#flexible-aggregates)) size.

Elements are accessed with generic load/store instructions that take a reference to an array:
```
(func $f (param $v (ref $vector))
  (store_elem $vector (get_local $v) (i32.const 1)
    (load_elem $vector (get_local $v) (i32.const 2))
  )
)
```
The element type of every access is checked at validation time.
The index is checked at execution time.
A trap occurs if the index is out of bounds.

Arrays are [allocated](#allocation) with `new` instructions that take a size and an initialization value as operands, yielding a reference:
```
(func $g
  (call $g (new_array $vector (i32.const 0) (i64.const 3.14)))
)
```
Arrays are garbage-collected.

The *length* of an array, i.e., the number of elements, can be inquired via the `load_length` instruction:
```
(load_length $vector (get_local $v))
```


### Packed Fields

Fields and elements can have a packed *storage type* `i8` or `i16`:
```
(type $s (struct (field $a i8) (field $b i16)))
(type $buf (array i8))
```
The order of fields is not observable, so implementations are free to optimize types by reordering fields or adding gaps for alignment.

Packed fields require special load/store instructions:
```
(load_field_packed_s $s $a (...))
(load_field_packed_u $s $a (...))
(store_field_packed $s $a (...) (...))
(load_elem_packed_s $s $a (...))
(load_elem_packed_u $s $a (...))
(store_elem_packed $s $a (...) (...))
```


### Mutability

Fields and elements can either be immutable or *mutable*:
```
(type $s (struct (field $a (mut i32)) (field $b i32)))
(type $a (array (mut i32)))
```
Store operators are only valid when targeting a mutable field or element.

Immutability is needed to enable the safe and efficient [subtyping](#subtyping), especially as needed for the [objects](#objects-and-mehtod-tables) use case.


### Nullability

By default references cannot be null,
avoiding any runtime overhead for null checks when using them.

Nullable references are available as separate types called `optref`.

TODO: Design a casting operator that avoids the need for control-flow sensitive typing.


### Defaultability

Most value types, including all numeric types and nullable references are *defaultable*, which means that they have 0/null as a default value.
Other reference types are not defaultable.

Certain restrictions apply to non-defaultable types:

* Local declarations of non-defaultable type must have an initializer.
* Allocations of aggregates with non-defaultable fields or elements must have initializers.

Objects whose members all have _mutable_ and _defaultable_ type may be allocated without initializers:
```
(type $s (struct (field $a (mut i32)) (field (mut (ref $s)))))
(type $a (array (mut f32)))

(new_default_struct $s)
(new_default_array $a (i32.const 100))
```


### Sharing

TODO: Distinguish types safe to share between threads in the type system.


## Other Reference Types

### Universal Type

The type `anyref` can hold references of any reference type.
It can be formed via [up casts](#casting),
and the original type can be recovered via [down casts](#casting).


### Foreign References

A new built-in value type called `foreignref` represents opaque pointers to objects on the _embedder_'s heap.

There are no operations to manipulate foreign references, but by passing them as parameters or results of exorted Wasm functions, embedder references (such as DOM objects) can safely be stored in or round-trip through Wasm code.
```
(type $s (struct (field $a i32) (field $x foreignref))

(func (export "f") (param $x foreignref)
  ...
)
```


### Function References

References can also be formed to function types, thereby introducing the notion of _typed function pointer_.

Function references can be called through `call_ref` instruction:
```
(type $t (func (param i32))

(func $f (param $x (ref $t))
  (call_ref (i32.const 5) (get_local $x))
)
```
Unlike `call_indirect`, this instruction is statically typed and does not involve any runtime check.

Values of function reference type are formed with the `ref_func` operator:
```
(func $g (param $x (ref $t))
  (call $f (ref_func $h))
)

(func $h (param i32) ...)
```

### Tagged Integers

Efficient implentations of untyped languages or languages with parametric polymorphism often rely on a _universal representation_, meaning that all values are word-sized.
At the same time, they want to avoid the cost of boxing wherever possible, by passing around integers unboxed, and using a tagging scheme to distinguish them from pointers in the GC.

To implement any such language efficiently, Wasm would need to provide such a mechanism by introducing a built-in reference type `intref` that represents tagged integers.
There are only two instructions for converting from and to such reference types:
```
tag : [i32] -> [intref]
tag : [intref] -> [i32]
```
Being reference types, tagged integers can be casted into `anyref`, and can participate in runtime type dispatch with `cast_down`.

TODO: To avoid portability hazards, the value range of `intref` has to be restricted to at most 31 bit?


## Type Structure

### Type Grammar

The type syntax can be captured in the following grammar:
```
num_type       ::=  i32 | i64 | f32 | f64
ref_type       ::=  (ref <def_type>) | foreignref | intref | anyref | anyfunc
value_type     ::=  <num_type> | <ref_type>

packed_type    ::=  i8 | i16
storage_type   ::=  <value_type> | <packed_type>
field_type     ::=  <storage_type> | (mut <storage_type>)

data_type      ::=  (struct <field_type>*) | (array <fixfield_type>)
func_type      ::=  (func <value_type>* <value_type>*)
def_type       ::=  <data_type> | <func_type>
```
where `value_type` is the type usable for parameters, local variables and the operand stack, and `def_type` describes the types that can be defined in the type section.


### Type Recursion

Through references, aggregate types can be *recursive*:
```
(type $list (struct (field i32) (field (ref $list))))
```
Mutual recursion is possible as well:
```
(type $tree (struct (field i32) (fiedl (ref $forest))))
(type $forest (struct (field (ref $tree)) (field (ref $forest))))
```

The [type grammar](#type-grammar) does not make recursion explicit. Semantically, it is assumed that types can be infinite regular trees by expanding all references in the type section, as is standard.
Folding that into a finite representation (such as a graph) is an implementation concern.


### Type Equivalence

In order to avoid spurious type incompatibilities at module boundaries,
all types are structural.
Aggregate types are considered equivalent when the unfoldings of their definitions are (note that field names are not part of the actual types, so are irrelevant):
```
(type $pt (struct (i32) (i32) (i32)))
(type $vec (struct (i32) (i32) (i32)))  ;; vec = pt
```
This extends to nested and recursive types:
```
(type $t1 (struct (type $pt) (ptr $t2)))
(type $t2 (struct (type $pt) (ptr $t1)))  ;; t2 = t1
(type $u (struct (type $vec) (ptr $u)))   ;; u = t1 = t2
```
Note: This is the standard definition of recursive structural equivalence for "equi-recursive" types.
Checking it is computationally equivalent to checking whether two FSAs are equivalent, i.e., it is a non-trivial algorithm (even though most practical cases will be trivial).
This may be a problem, in which case we need to fall back to a more restrictive definition, although it is unclear what exactly that would be.


### Subtyping

Subtyping is designed to be _non-coercive_, i.e., never requires any underlying value conversion.

The subtyping relation is the reflexive transitive closure of a few basic rules:

1. The `anyref` type is a supertype of every reference type (top reference type).
2. The ` anyfunc` type is a supertype of every function type.
3. A structure type is a supertype of another structure type if its field list is a prefix of the other (width subtyping).
4. A structure type is a supertype of another structure type if they have the same fields and for each field type:
   - The field is mutable in both types and the storage types are the same.
   - The field is immutable in both types and their storage types are in (covariant) subtype relation (depth subtyping).
5. An array type is a supertype of another array type if:
   - Both element types are mutable and the storage types are the same.
   - Both element types are immutable and their storage types are in
(covariant) subtype relation (depth subtyping).
6. A function type is a supertype of another function type if they have the same number of parameters and results, and:
   - For each parameter, the supertype's parameter type is a subtype of the subtype's parameter type (contravariance).
   - For each result, the supertype's parameter type is a supertype of the subtype's parameter type (covariance).

Note: Like [type equivalence](#type-equivalence), subtyping is *structural*.
The above is the standard (co-inductive) definition, which is the most general definition that is sound.
Checking it is computationally equivalent to checking whether one FSA recognises a sublanguage of another FSA, i.e., it is a non-trivial algorithm (even though most practical cases will be trivial).
Like with type equivalence, this may be a problem, in which case a more restrictive definition might be needed.

Subtyping could be relaxed such that mutable fields/elements could be subtypes of immutable ones.
That would simplify creation of immutable objects, by first creating them as mutable, initialize them, and then cast away their constness.
On the other hand, it means that immutable fields can still change, preventing various access optimizations.
(Another alternative would be a three-state mutability algebra.)


### Casting

To minimize typing overhead, all uses of subtyping are _explicit_ through casts.
The instruction
```
(cast_up <type1> <type2> (...))
```
casts the operand of type `<type1>` to type `<type2>`.
An upcast is always safe.
It is a validation error if the operand's type is not `<type1>`, or if `<type1>` is not a subtype of `<type2>`.

Casting is also possible in the reverse direction:
```
(cast_down <type1> <type2> $label (...))
```
also casts the operand of type `<type1>` to type `<type2>`.
It is a validation error if the operand's type is not `<type1>`, or if `<type1>` is not a subtype of `<type2>`.
However, a downcast may fail at runtime if the operand's type is not `<type2>`, in which case control branches to `$label`, with the operand as argument.

Downcasts can be used to implement runtime type analysis, or to recover the concrete type of an object that has been cast to `anyref` to emulate parametric polymorphism.

Note: Casting could be extended to allow reinterpreting any sequence of _transparent_ (i.e., non-reference) fields of an aggregate type with any other transparent sequence of the same size.
That would require constraining the ability of implementations to reorder or align fields.


### Import and Export

Types can be exported from and imported into a module.

TODO: The ability to import types makes the type and import sections interdependent.


## Possible Extension: Variants

TODO


## Possible Extension: Closures

TODO


## Possible Extension: Nesting

* Want to represent structures embedding arrays contiguously.
* Want to represent arrays of structures contiguously (and maintaining locality).
* Access to nested data structures needs to be decomposable.
* Too much implementation complexity should be avoided.

Examples are e.g. the value types in C#, where structures can be unboxed members of arrays, or a language like Go.

Example (C-ish syntax with GC):
```
struct A {
  char x;
  int y[30];
  float z;
}

// Iterating over an (inner) array
A aa[20];
for (int i = 0..19) {
  A* a = aa[i];
  print(a->x);
  for (int j = 0..29) {
    print(a->y[j]);
  }
}
```

Needs:

* incremental access to substructures,
* interior references.

Two main challenges arise:

* Interior pointers, in full generality, introduce significant complications to GC. This can be avoided by distinguishing interior references from regular ones. That way, interior pointers can be represented as _fat pointers_ without complicating the GC, and their use is mostly pay-as-you-go.

* Aggregate objects, especially arrays, can nest arbitrarily. At each nesting level, they may introduce arbitrary mixes of pointer and non-pointer representations that the GC must know about. An efficient solution essentially requires that the GC traverses (an abstraction of) the type structure.


### Basic Nesting

* Aggregate types can be field types.
* They are unboxed, i.e., nesting them describes one flat value in memory; references enforce boxing.

```
(type $colored-point (struct (type $point) (i16)))
```
Here, `type $point` refers to the previously defined `$point` structure type.


### Interior References

Interior References are another new form of value type:
```
(local $ip (inref $point))
```
Interior references can point to unboxed aggregates, while regular ones cannot.
Every regular reference can be converted into an interior reference (but not vice versa) [details TBD].


### Access

* All access operators are also valid on interior references.

* If a loaded structure field or array element has aggregate type itself, it yields an interior reference to the respective aggregate type, which can be used to access the nested aggregate:
  ```
  (load_field (load_field (new $colored-point) 0) 0)
  ```

* It is not possible to store to a fields or elements that have aggregate type.
  Writing to a nested structure or array requires combined uses of `load_field`/`load_elem` to acquire the interior reference and `store_field`/`store_elem` to its contents:
  ```
  (store_field (load_field (new $color-point) 0) 0 (f64.const 1.2))
  ```

TODO: What is the form of the allocation instruction for aggregates that nest others, especially wrt field initializers?


### Fixed Arrays

Arrays can only be nested into other aggregates if they have a *fixed* size.
Fixed arrays are a second version of array type that has a size (expressed as a constant expression) in addition to an element type:
```
(type $a (array i32 (i32.const 100)))
```

TODO: The ability to use constant expressions makes the type, global, and import sections interdependent.


### Flexible Aggregates

Arrays without a static size are called *flexible*.
Flexible aggregates cannot be used as field or element types.

However, it is a common pattern wanting to define structs that end in an array of dynamic size.
To support this, flexible arrays could be allowed for the _last_ field of a structure:
```
(type $flex-array (array i32))
(type $file (struct (field i32) (field (type $flex-array))))
```
Such a structure is itself called *flexible*.
This notion can be generalized recursively: flexible aggregates cannot be used as field or member types, except for the last field of a structure.

Like a flexible array, allocating a flexible structure would require giving a dynamic size operand for its flexible tail array (which is a direct or indirect last field).


### Type Structure

With nesting and flexible aggregates, the type grammar generalizes as follows:
```
fix_field_type   ::=  <storage_type> | (mut <storage_type>) | <fix_data_type>
flex_field_type  ::=  <flex_data_type>

fix_data_type    ::=  (struct <fix_field_type>*) | (array <fix_field_type> <expr>)
flex_data_type   ::=  (struct <fix_field_type>* <flex_field_type>) | (array <fix_field_type>)
data_type        ::=  <fix_data_type> | <flex_data_type>
```
However, additional checks need to apply to (mutually) recursive type definitions in order to ensure well-foundedness of the recursion.
For example,
```
(type $t (struct (type $t)))
```
is not valid.
For example, well-foundedness can be ensured by requiring that the *nesting height* of any `data_type`, derivable by the following inductive definition, is finite:
```
|<storage_type>|               = 0
|(mut <storage_type>)|         = 0
|(struct <field_type>*)|       = 1 + max{|<field_type>|*}
|(array <field_type> <expr>?)| = 1 + |<field_type>|
```