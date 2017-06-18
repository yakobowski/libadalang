with Ada.Command_Line;
with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Unbounded.Hash;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Interfaces; use Interfaces;

with GNAT.Traceback.Symbolic;

with GNATCOLL.Projects; use GNATCOLL.Projects;
with GNATCOLL.VFS;      use GNATCOLL.VFS;

with Langkit_Support.Adalog.Debug;   use Langkit_Support.Adalog.Debug;
with Langkit_Support.Diagnostics;
with Langkit_Support.Slocs;          use Langkit_Support.Slocs;
with Langkit_Support.Text;           use Langkit_Support.Text;
with Libadalang.Analysis;            use Libadalang.Analysis;
with Libadalang.Unit_Files;          use Libadalang.Unit_Files;
with Libadalang.Unit_Files.Projects; use Libadalang.Unit_Files.Projects;

with Put_Title;

procedure Nameres is

   --  Holders for options that command-line can tune

   Charset : Unbounded_String := To_Unbounded_String ("");
   --  Charset to use in order to parse analysis units

   Quiet   : Boolean := False;
   --  If True, don't display anything but errors on standard output

   UFP     : Unit_Provider_Access;
   --  When project file handling is enabled, corresponding unit provider

   Ctx     : Analysis_Context := No_Analysis_Context;

   function Text (N : access Ada_Node_Type'Class) return String
   is (Image (N.Text));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Strip_Prefix (S, Prefix : String) return String is
     (S (S'First + Prefix'Length .. S'Last));

   function "+" (S : String) return Unbounded_String
      renames To_Unbounded_String;
   function "+" (S : Unbounded_String) return String renames To_String;

   function "<" (Left, Right : Ada_Node) return Boolean is
     (Left.Sloc_Range.Start_Line < Right.Sloc_Range.Start_Line);
   procedure Sort is new Ada.Containers.Generic_Array_Sort
     (Index_Type   => Positive,
      Element_Type => Ada_Node,
      Array_Type   => Ada_Node_Array,
      "<"          => "<");

   function Decode_Boolean_Literal (T : Text_Type) return Boolean is
     (Boolean'Wide_Wide_Value (T));
   procedure Process_File (Unit : Analysis_Unit; Filename : String);

   --------------
   -- New_Line --
   --------------

   procedure New_Line is begin
      if not Quiet then
         Ada.Text_IO.New_Line;
      end if;
   end New_Line;

   --------------
   -- Put_Line --
   --------------

   procedure Put_Line (S : String) is begin
      if not Quiet then
         Ada.Text_IO.Put_Line (S);
      end if;
   end Put_Line;

   ---------
   -- Put --
   ---------

   procedure Put (S : String) is begin
      if not Quiet then
         Ada.Text_IO.Put (S);
      end if;
   end Put;

   ------------------
   -- Resolve_Node --
   ------------------

   procedure Resolve_Node (N : Ada_Node) is
      function Safe_Image
        (Node : access Ada_Node_Type'Class) return String
      is (if Node = null then "None" else Image (Node.Short_Image));

      function Is_Expr (N : Ada_Node) return Boolean
      is (N.all in Expr_Type'Class);
   begin
      if Langkit_Support.Adalog.Debug.Debug then
         N.Assign_Names_To_Logic_Vars;
      end if;
      if N.P_Resolve_Names then
         for Node of N.Find (Is_Expr'Access).Consume loop
            declare
               P_Ref  : Entity := Expr (Node).P_Ref_Val;
               P_Type : Entity := Expr (Node).P_Type_Val;
            begin
               if not Quiet then
                  Put_Line
                    ("Expr: " & Safe_Image (Node) & ", references "
                     & Safe_Image (P_Ref.El) & ", type is "
                     & Safe_Image (P_Type.El));
               end if;
               Dec_Ref (P_Ref);
               Dec_Ref (P_Type);
            end;
         end loop;
      else
         Put_Line ("Resolution failed for node " & Safe_Image (N));
      end if;
   end Resolve_Node;

   ------------------
   -- Process_File --
   ------------------

   procedure Process_File (Unit : Analysis_Unit; Filename : String) is

      function Safe_Image
        (Node : access Ada_Node_Type'Class) return String
      is
        (if Node = null then "None" else Image (Node.Short_Image));

   begin
      if Has_Diagnostics (Unit) then
         for D of Diagnostics (Unit) loop
            Put_Line ("error: " & Filename & ": "
                      & Langkit_Support.Diagnostics.To_Pretty_String (D));
         end loop;
         return;
      end if;
      Populate_Lexical_Env (Unit);

      declare
         --  Configuration for this unit
         Display_Slocs        : Boolean := False;
         Display_Short_Images : Boolean := False;

         Empty     : Boolean := True;
         Last_Line : Natural := 0;
         P_Node    : Pragma_Node;

         function Is_Pragma_Node (N : Ada_Node) return Boolean is
           (Kind (N) = Ada_Pragma_Node);

         function Pragma_Name return String is (Text (P_Node.F_Id.F_Tok));

      begin
         --  Print what entities are found for expressions X in all the "pragma
         --  Test (X)" we can find in this unit.
         for Node of Root (Unit).Find (Is_Pragma_Node'Access).Consume loop

            P_Node := Pragma_Node (Node);

            --  If this pragma and the previous ones are not on adjacent lines,
            --  do not make them adjacent in the output.
            if Pragma_Name /= "Config" then
               if Last_Line /= 0
                     and then
                  Natural (Node.Sloc_Range.Start_Line) - Last_Line > 1
               then
                  New_Line;
               end if;
               Last_Line := Natural (Node.Sloc_Range.End_Line);
            end if;

            if Pragma_Name = "Config" then
               --  Handle testcase configuration pragmas for this file
               for Arg of P_Node.F_Args.Children loop
                  declare
                     A     : constant Pragma_Argument_Assoc :=
                        Pragma_Argument_Assoc (Arg);

                     pragma Assert (A.F_Id.all in Identifier_Type'Class);
                     Name  : constant Text_Type := Text (A.F_Id.F_Tok);

                     pragma Assert (A.F_Expr.all in Identifier_Type'Class);
                     Value : constant Text_Type :=
                        Text (Identifier (A.F_Expr).F_Tok);
                  begin
                     if Name = "Display_Slocs" then
                        Display_Slocs := Decode_Boolean_Literal (Value);
                     elsif Name = "Display_Short_Images" then
                        Display_Short_Images := Decode_Boolean_Literal (Value);
                     else
                        raise Program_Error with
                          ("Invalid configuration: " & Image (Name, True));
                     end if;
                  end;
               end loop;

            elsif Pragma_Name = "Section" then
               --  Print headlines
               declare
                  pragma Assert (P_Node.F_Args.Child_Count = 1);
                  Arg : constant Expr := P_Node.F_Args.Item (1).P_Assoc_Expr;
                  pragma Assert (Arg.all in String_Literal_Type'Class);

                  Tok : constant Token_Type := String_Literal (Arg).F_Tok;
                  T   : constant Text_Type := Text (Tok);
               begin
                  Put_Title
                    ('-', Image (T (T'First + 1 .. T'Last - 1)));
               end;
               Empty := True;

            elsif Pragma_Name = "Test" then
               --  Perform name resolution
               declare
                  pragma Assert (P_Node.F_Args.Child_Count = 1);
                  Arg      : constant Expr
                    := P_Node.F_Args.Item (1).P_Assoc_Expr;
                  Entities : Ada_Node_Array_Access := Arg.P_Matching_Nodes;
               begin
                  Put_Line (Text (Arg) & " resolves to:");
                  Sort (Entities.Items);
                  for E of Entities.Items loop
                     Put ("    " & (if Display_Short_Images
                                    then Image (E.Short_Image)
                                    else Text (E)));
                     if Display_Slocs then
                        Put_Line (" at " & Image (Start_Sloc (E.Sloc_Range)));
                     else
                        New_Line;
                     end if;
                  end loop;
                  if Entities.N = 0 then
                     Put_Line ("    <none>");
                  end if;
                  Dec_Ref (Entities);
               end;
               Empty := False;

            elsif Pragma_Name = "Test_Statement" then
               pragma Assert (P_Node.F_Args.Child_Count = 0);
               Resolve_Node (P_Node.Previous_Sibling);
               Empty := False;

            elsif Pragma_Name = "Test_Block" then
               pragma Assert (P_Node.F_Args.Child_Count = 0);
               declare
                  Block : Ada_Node :=
                    (if Kind (P_Node.Parent.Parent) = Ada_Compilation_Unit
                     then Compilation_Unit (P_Node.Parent.Parent).F_Body
                     else P_Node.Previous_Sibling);

                  function Is_Xref_Entry_Point (N : Ada_Node) return Boolean
                  is (N.P_Xref_Entry_Point);
               begin
                  for Node
                    of Block.Find (Is_Xref_Entry_Point'Access).Consume
                  loop
                     Resolve_Node (Node);
                  end loop;
               end;
               Empty := False;
            end if;
         end loop;
         if not Empty then
            New_Line;
         end if;
      end;
   end Process_File;

   package String_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);
   Files : String_Vectors.Vector;

   With_Default_Project : Boolean := False;
   Project_File         : Unbounded_String;
   Scenario_Vars        : String_Vectors.Vector;

begin
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      declare
         Arg : constant String := Ada.Command_Line.Argument (I);
      begin
         if Arg in "--quiet" | "-q" then
            Quiet := True;
         elsif Arg in "--trace" | "-T" then
            Set_Debug_State (Trace);
         elsif Arg in "--debug" | "-D" then
            Set_Debug_State (Step);
         elsif Starts_With (Arg, "--charset") then
            Charset := +Strip_Prefix (Arg, "--charset=");
         elsif Arg = "--with-default-project" then
            With_Default_Project := True;
         elsif Starts_With (Arg, "-P") then
            Project_File := +Strip_Prefix (Arg, "-P");
         elsif Starts_With (Arg, "-X") then
            Scenario_Vars.Append (+Strip_Prefix (Arg, "-X"));
         elsif Starts_With (Arg, "--") then
            Put_Line ("Invalid argument: " & Arg);
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         else
            Files.Append (+Arg);
         end if;
      end;
   end loop;

   if With_Default_Project or else Length (Project_File) > 0 then
      declare
         Filename : constant String := +Project_File;
         Env      : Project_Environment_Access;
         Project  : constant Project_Tree_Access := new Project_Tree;
      begin
         Initialize (Env);

         --  Set scenario variables
         for Assoc of Scenario_Vars loop
            declare
               A : constant String := +Assoc;
               Eq_Index : Natural := A'First;
            begin
               while Eq_Index <= A'Length and then A (Eq_Index) /= '=' loop
                  Eq_Index := Eq_Index + 1;
               end loop;
               if Eq_Index not in A'Range then
                  Put_Line ("Invalid scenario variable: -X" & A);
                  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
                  return;
               end if;
               Change_Environment
                 (Env.all,
                  A (A'First .. Eq_Index - 1),
                  A (Eq_Index + 1 .. A'Last));
            end;
         end loop;

         if Filename'Length = 0 then
            Load_Empty_Project (Project.all, Env);
         else
            Load (Project.all, Create (+Filename), Env);
         end if;
         UFP := new Project_Unit_Provider_Type'(Create (Project, Env, True));
      end;
   end if;

   Ctx := Create
     (Charset       => +Charset,
      Unit_Provider => Unit_Provider_Access_Cst (UFP));

   for F of Files loop
      declare
         File : constant String := +F;
         Unit : Analysis_Unit;
      begin
         Unit := Get_From_File (Ctx, File);
         Put_Title ('#', "Analyzing " & File);
         Process_File (Unit, File);
      end;
   end loop;

   Destroy (Ctx);
   Destroy (UFP);
   Put_Line ("Done.");
exception
   when E : others =>
      Put_Line ("Traceback:");
      Put_Line ("");
      Put_Line (GNAT.Traceback.Symbolic.Symbolic_Traceback (E));
      raise;
end Nameres;