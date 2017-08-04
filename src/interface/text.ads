--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"

with Ada.Containers;
with Ada.Strings.UTF_Encoding;
with Ada.Finalization;
with System.Storage_Elements;
private with Ada.Unchecked_Conversion;

package Text is
   --  this package defines a reference-counted string pointer type. it is used
   --  for all YAML data entities and relieves the user from the need to
   --  manually dispose events created by the parser.
   --
   --  typically, YAML content strings are deallocated in the same order as they
   --  are allocated. this knowledge is built into a storage pool for efficient
   --  memory usage and to avoid fragmentation.
   --
   --  to be able to efficiently interface with C, this package allocates its
   --  strings so that they can directly be passed on to C without the need to
   --  copy any data. Use the subroutines Export and Delete_Exported to get
   --  C-compatible string values from a Reference. these subroutines also
   --  take care of reference counting for values exposed to C. this means that
   --  after exporting a value, you *must* eventually call Delete_Exported in
   --  order for the value to be freed.
   --
   --  HINT: this package makes use of compiler implementation details and may
   --  not work with other compilers. however, since there currently are no
   --  Ada 2012 compilers but GNAT, this is not considered a problem.

   --  the pool allocates the memory it uses on the heap. it is allowed for the
   --  pool to vanish while References created on it are still around. the
   --  heap memory is reclaimed when the pool itself and all References
   --  created by it vanish.
   --
   --  this type has pointer semantics in order to allow the usage of the same
   --  pool at different places without the need of access types. copying a
   --  value of this type will make both values use the same memory. use Create
   --  to generate a new independent pool.

   --  all strings generated by Yaml are encoded in UTF-8, regardless of input
   --  encoding.
   subtype UTF_8_String is Ada.Strings.UTF_Encoding.UTF_8_String;
   type UTF_8_String_Access is access UTF_8_String;

   subtype Pool_Offset is System.Storage_Elements.Storage_Offset
   range 0 .. System.Storage_Elements.Storage_Offset (Integer'Last);

   --  this type is used to forbid the user to copy the pointer to UTF_8_String
   --  into a variable of a named access type. thus, we can be sure that no
   --  pointer to the String outlives the smart pointers.
   type Accessor (Data : not null access constant UTF_8_String) is
     limited private with Implicit_Dereference => Data;

   --  this is a smart pointer. use Value to access its value.
   type Reference is tagged private with Constant_Indexing => Element;

   function Value (Object : Reference) return Accessor with Inline;

   --  shortcut for Object.Value.Data'Length
   function Length (Object : Reference) return Natural with Inline;

   function "&" (Left, Right : Reference) return String with Inline;
   function "&" (Left : Reference; Right : String)
                 return String with Inline;
   function "&" (Left : Reference; Right : Character) return String
     with Inline;
   function "&" (Left : String; Right : Reference)
                 return String with Inline;
   function "&" (Left : Character; Right : Reference) return String
     with Inline;

   --  compares the string content of two Content values.
   function "=" (Left, Right : Reference) return Boolean with Inline;

   function "=" (Left : Reference; Right : String) return Boolean with Inline;
   function "=" (Left : String; Right : Reference) return Boolean with Inline;

   function Hash (Object : Reference) return Ada.Containers.Hash_Type;

   function Element (Object : Reference; Position : Positive) return Character;

   --  equivalent to the empty string. default value for References.
   Empty : constant Reference;

   --  this can be used for constant Reference values that are declared at
   --  library level where no Pool is available. References pointing to a
   --  Constant_Content_Holder are never freed.
   type Constant_Instance (<>) is private;

   --  note that there is a limit of 128 characters for Content values created
   --  like this.
   function Hold (Content : String) return Constant_Instance;

   --  get a Reference value which is a reference to the string contained in the
   --  Holder.
   function Held (Holder : Constant_Instance) return Reference;

   --  used for exporting to C interfaces
   subtype Exported is System.Address;

   --  increases the reference count and returns a value that can be used in
   --  places where C expects a `const char*` value.
   function Export (Object : Reference) return Exported;

   --  creates a content value from an exported pointer
   function Import (Pointer : Exported) return Reference;

   --  decreases the reference count (and so possibly deallocates the value).
   procedure Delete_Exported (Pointer : Exported);
private
   --  this forces GNAT to store the First and Last dope values right before
   --  the first element of the String. we use that to our advantage.
   for UTF_8_String_Access'Size use Standard'Address_Size;

   type Chunk_Index_Type is range 1 .. 10;
   subtype Refcount_Type is Integer range 0 .. 2 ** 24 - 1;

   --  the pool consists of multiple chunks of memory. strings are allocated
   --  inside the chunks.
   type Pool_Array is array (Pool_Offset range <>) of System.Storage_Elements.Storage_Element;
   type Chunk is access Pool_Array;
   type Chunk_Array is array (Chunk_Index_Type) of Chunk;
   type Usage_Array is array (Chunk_Index_Type) of Natural;

   --  the idea is that Cur is the pointer to the active Chunk. all new strings
   --  are allocated in that active Chunk until there is no more space. then,
   --  we allocate a new Chunk of twice the size of the current one and make
   --  that the current Chunk. the old Chunk lives on until all Content strings
   --  allocated on it vanish. Usage is the number of strings currently
   --  allocated on the Chunk and is used as reference count. the current Chunk
   --  has Usage + 1 which prevents its deallocation even if the last Content
   --  string on it vanishes. the Content type's finalization takes care of
   --  decrementing the Usage value that counts allocated strings, while the
   --  String_Pool type's deallocation takes care of removing the +1 for the
   --  current Chunk.
   --
   --  we treat each Chunk basically as a bitvector ring list, and Pos is the
   --  current offset in the current Chunk. instead of having a full bitvector
   --  for allocating, we use the dope values from the strings that stay in the
   --  memory after deallocation. besides the First and Last values, we also
   --  store a reference count in the dope. so when searching for a place to
   --  allocate a new string, we can skip over regions that have a non-zero
   --  reference count in their header, and those with a 0 reference count are
   --  available space. compared to a real bitvector, we always have the
   --  information of the length of an free region available. we can avoid
   --  fragmentation by merging a region that is freed with the surrounding free
   --  regions.
   type Pool_Data is record
      Refcount : Refcount_Type := 1;
      Chunks : Chunk_Array;
      Usage  : Usage_Array := (1 => 1, others => 0);
      Cur    : Chunk_Index_Type := 1;
      Pos    : Pool_Offset;
   end record;

   type Pool_Data_Access is access Pool_Data;
   for Pool_Data_Access'Size use Standard'Address_Size;

   --  this is the dope vector of each string allocated in a Chunk. it is put
   --  immediately before the string's value. note that the First and Last
   --  elements are at the exact positions where GNAT searches for the string's
   --  boundary dope. this allows us to access those values for maintaining the
   --  ring list.
   type Header is record
      Pool : Pool_Data_Access;
      Chunk_Index : Chunk_Index_Type;
      Refcount : Refcount_Type := 1;
      First, Last : Pool_Offset;
   end record;

   Chunk_Index_Start : constant := Standard'Address_Size;
   Refcount_Start    : constant := Standard'Address_Size + 8;
   First_Start       : constant := Standard'Address_Size + 32;
   Last_Start        : constant := First_Start + Integer'Size;
   Header_End        : constant := Last_Start + Integer'Size - 1;

   for Header use record
      Pool        at 0 range 0 .. Chunk_Index_Start - 1;
      Chunk_Index at 0 range Chunk_Index_Start .. Refcount_Start - 1;
      Refcount    at 0 range Refcount_Start .. First_Start - 1;
      First       at 0 range First_Start .. Last_Start - 1;
      Last        at 0 range Last_Start .. Header_End;
   end record;
   for Header'Size use Header_End + 1;

   use type System.Storage_Elements.Storage_Offset;

   Header_Size : constant Pool_Offset := Header'Size / System.Storage_Unit;

   type Constant_Instance (Length : Positive) is record
      Data : String (1 .. Length);
   end record;

   Chunk_Start_Index : constant := Chunk_Index_Start / System.Storage_Unit + 1;
   Refcount_Start_Index : constant := Refcount_Start / System.Storage_Unit + 1;
   First_Start_Index : constant := First_Start / System.Storage_Unit + 1;
   Last_Start_Index  : constant := Last_Start / System.Storage_Unit + 1;
   End_Index         : constant := (Header_End + 1) / System.Storage_Unit;

   Empty_Holder : constant Constant_Instance :=
     (Length => Positive (Header_Size) + 1, Data =>
          (1 .. Chunk_Start_Index - 1 => Character'Val (0),
           Chunk_Start_Index .. Refcount_Start_Index - 1 => <>,
           Refcount_Start_Index .. First_Start_Index - 2 => Character'Val (0),
           First_Start_Index - 1 => Character'Val (1),
           First_Start_Index .. Last_Start_Index - 2 => Character'Val (0),
           Last_Start_Index - 1 => Character'Val (1),
           Last_Start_Index .. End_Index => Character'Val (0),
           End_Index + 1 => Character'Val (0)));

   type Accessor (Data : not null access constant UTF_8_String) is limited
      record
         --  holds a copy of the smart pointer, so the string cannot be freed
         --  while the accessor lives.
         Hold : Reference;
      end record;

   function To_UTF_8_String_Access is new Ada.Unchecked_Conversion
     (System.Address, UTF_8_String_Access);

   type Reference is new Ada.Finalization.Controlled with record
      Data : UTF_8_String_Access :=
        To_UTF_8_String_Access (Empty_Holder.Data (Positive (Header_Size) + 1)'Address);
   end record;

   overriding procedure Adjust (Object : in out Reference);
   overriding procedure Finalize (Object : in out Reference);

   Empty : constant Reference :=
     (Ada.Finalization.Controlled with Data => <>);

   --  it is important that all allocated strings are aligned to the header
   --  length. else, it may happen that we generate a region of free memory that
   --  is not large enough to hold a header – but we need to write the header
   --  there to hold information for the ring list. therefore, whenever we
   --  calculate offsets, we use this to round them up to a multiple of
   --  Header_Size.
   function Round_To_Header_Size (Length : Pool_Offset)
                                  return Pool_Offset is
     ((Length + Header_Size - 1) / Header_Size * Header_Size);

   procedure Decrease_Usage (Pool : in out Pool_Data_Access;
                             Chunk_Index : Chunk_Index_Type);

   function Fitting_Position (Length : Pool_Offset;
                              P : Pool_Data_Access) return System.Address;

   function Header_Of (S : UTF_8_String_Access) return not null access Header;
end Text;

