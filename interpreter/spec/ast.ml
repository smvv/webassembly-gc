(*
 * Throughout the implementation we use consistent naming conventions for
 * syntactic elements, associated with the types defined here and in a few
 * other places:
 *
 *   x : var
 *   v : value
 *   e : instrr
 *   f : func
 *   m : module_
 *
 *   t : value_type
 *   s : func_type
 *   c : context / config
 *
 * These conventions mostly follow standard practice in language semantics.
 *)

open Types


(* Operators *)

module IntOp =
struct
  type unop = Clz | Ctz | Popcnt
  type binop = Add | Sub | Mul | DivS | DivU | RemS | RemU
             | And | Or | Xor | Shl | ShrS | ShrU | Rotl | Rotr
  type testop = Eqz
  type relop = Eq | Ne | LtS | LtU | GtS | GtU | LeS | LeU | GeS | GeU
  type cvtop = ExtendSI32 | ExtendUI32 | WrapI64
             | TruncSF32 | TruncUF32 | TruncSF64 | TruncUF64
             | ReinterpretFloat
end

module FloatOp =
struct
  type unop = Neg | Abs | Ceil | Floor | Trunc | Nearest | Sqrt
  type binop = Add | Sub | Mul | Div | Min | Max | CopySign
  type testop
  type relop = Eq | Ne | Lt | Gt | Le | Ge
  type cvtop = ConvertSI32 | ConvertUI32 | ConvertSI64 | ConvertUI64
             | PromoteF32 | DemoteF64
             | ReinterpretInt
end

module ObjOp =
struct
  type unop
  type binop
  type testop
  type relop = Eq | Ne
  type cvtop
end

module I32Op = IntOp
module I64Op = IntOp
module F32Op = FloatOp
module F64Op = FloatOp

type unop = (I32Op.unop, I64Op.unop, F32Op.unop, F64Op.unop, ObjOp.unop) Values.op
type binop = (I32Op.binop, I64Op.binop, F32Op.binop, F64Op.binop, ObjOp.binop) Values.op
type testop = (I32Op.testop, I64Op.testop, F32Op.testop, F64Op.testop, ObjOp.testop) Values.op
type relop = (I32Op.relop, I64Op.relop, F32Op.relop, F64Op.relop, ObjOp.relop) Values.op
type cvtop = (I32Op.cvtop, I64Op.cvtop, F32Op.cvtop, F64Op.cvtop, ObjOp.cvtop) Values.op

type 'a memop =
  {ty : value_type; align : int; offset : Memory.offset; sz : 'a option}
type loadop = (Memory.mem_size * Memory.extension) memop
type storeop = Memory.mem_size memop


(* Expressions *)

type var = int32 Source.phrase
type literal = Values.value Source.phrase

type loadfieldop = {struct_ : var; field : int32}
type storefieldop = {struct_ : var; field : int32}

type instr = instr' Source.phrase
and instr' =
  | Unreachable                       (* trap unconditionally *)
  | Nop                               (* do nothing *)
  | Block of stack_type * instr list  (* execute in sequence *)
  | Loop of stack_type * instr list   (* loop header *)
  | If of stack_type * instr list * instr list  (* conditional *)
  | Br of var                         (* break to n-th surrounding label *)
  | BrIf of var                       (* conditional break *)
  | BrTable of var list * var         (* indexed break *)
  | Return                            (* break from function body *)
  | Call of var                       (* call function *)
  | CallIndirect of var               (* call function through table *)
  | Drop                              (* forget a value *)
  | Select                            (* branchless conditional *)
  | GetLocal of var                   (* read local variable *)
  | SetLocal of var                   (* write local variable *)
  | TeeLocal of var                   (* write local variable and keep value *)
  | GetGlobal of var                  (* read global variable *)
  | SetGlobal of var                  (* write global variable *)
  | NewObject of var                  (* zero-initialise a GC object *)
  | LoadField of loadfieldop          (* load from field of a GC object *)
  | StoreField of storefieldop        (* store to field of a GC object *)
  | Load of loadop                    (* read memory at address *)
  | Store of storeop                  (* write memory at address *)
  | CurrentMemory                     (* size of linear memory *)
  | GrowMemory                        (* grow linear memory *)
  | Const of literal                  (* constant *)
  | Test of testop                    (* numeric test *)
  | Compare of relop                  (* numeric comparison *)
  | Unary of unop                     (* unary numeric operator *)
  | Binary of binop                   (* binary numeric operator *)
  | Convert of cvtop                  (* conversion *)


(* Globals & Functions *)

type const = instr list Source.phrase

type global = global' Source.phrase
and global' =
{
  gtype : global_type;
  value : const;
}

type func = func' Source.phrase
and func' =
{
  ftype : var;
  locals : value_type list;
  body : instr list;
}


(* Tables & Memories *)

type table = table' Source.phrase
and table' =
{
  ttype : table_type;
}

type memory = memory' Source.phrase
and memory' =
{
  mtype : memory_type;
}

type 'data segment = 'data segment' Source.phrase
and 'data segment' =
{
  index : var;
  offset : const;
  init : 'data;
}

type table_segment = var list segment
type memory_segment = string segment


(* Modules *)

type export_kind = export_kind' Source.phrase
and export_kind' = FuncExport | TableExport | MemoryExport | GlobalExport

type export = export' Source.phrase
and export' =
{
  name : string;
  ekind : export_kind;
  item : var;
}

type import_kind = import_kind' Source.phrase
and import_kind' =
  | FuncImport of var
  | TableImport of table_type
  | MemoryImport of memory_type
  | GlobalImport of global_type

type import = import' Source.phrase
and import' =
{
  module_name : string;
  item_name : string;
  ikind : import_kind;
}

type module_ = module_' Source.phrase
and module_' =
{
  types : func_or_type_descr_type list;
  globals : global list;
  tables : table list;
  memories : memory list;
  funcs : func list;
  start : var option;
  elems : var list segment list;
  data : string segment list;
  imports : import list;
  exports : export list;
}


(* Auxiliary functions *)

let empty_module =
{
  types = [];
  globals = [];
  tables = [];
  memories = [];
  funcs = [];
  start = None;
  elems  = [];
  data = [];
  imports = [];
  exports = [];
}

open Source

let export_kind_of_import_kind = function
  | FuncImport _ -> FuncExport
  | TableImport _ -> TableExport
  | MemoryImport _ -> MemoryExport
  | GlobalImport _ -> GlobalExport

let import_type (m : module_) (im : import) : external_type =
  let {ikind; _} = im.it in
  match ikind.it with
  | FuncImport x ->
    let fn = match (Lib.List32.nth m.it.types x.it) with
    | FuncElemType f -> f
    | TypeDescrElemType t -> assert false
    in ExternalFuncType fn
  | TableImport t -> ExternalTableType t
  | MemoryImport t -> ExternalMemoryType t
  | GlobalImport t -> ExternalGlobalType t

let export_type (m : module_) (ex : export) : external_type =
  let {ekind; item; _} = ex.it in
  let rec find i = function
    | im::ims when export_kind_of_import_kind im.it.ikind.it = ekind.it ->
      if i = 0l then import_type m im else find (Int32.sub i 1l) ims
    | im::ims -> find i ims
    | [] ->
      let open Lib.List32 in
      match ekind.it with
      | FuncExport ->
        let fn = match (nth m.it.types (nth m.it.funcs i).it.ftype.it) with
        | FuncElemType f -> f
        | TypeDescrElemType t -> assert false
        in ExternalFuncType fn
      | TableExport -> ExternalTableType (nth m.it.tables i).it.ttype
      | MemoryExport -> ExternalMemoryType (nth m.it.memories i).it.mtype
      | GlobalExport -> ExternalGlobalType (nth m.it.globals i).it.gtype
  in find item.it m.it.imports
