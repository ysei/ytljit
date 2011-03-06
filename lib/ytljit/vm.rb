module YTLJit

=begin
Typical struct of node

def fact(x)
  if x == 0 then
    return 1
  else
    return x * fact(x - 1)
  end
end


MethodTopNode
  name -> "fact"     
  body  
   |
LocalFrameInfo
  frame       -- infomation of frame (access via insptance methodes)
  body
   |
GuardInfo
  type_list -> [[a, Fixnum], [v, Fixnum]], [[a, Float], [v, Fixnum]] ...
  body
       # Compile each element of type_list.
   |
BranchIfNode
  epart------------------+
  tpart----------------+ |
  cond                 | |
   |                   | |
SendNode               | |
  func -> ==           | |
  arg[0]------------+  | |
  arg[1]            |  | |
   |                |  | |
LiteralNode         |  | |
  value -> 0        |  | |
                    |  | |
    +---------------+  | |
    |                  | |
LocalVarNode           | |
  offset -> 0          | |
  depth -> 0           | |
                       | |
    +------------------+ |
    |                    |
MethodEndNode            |
  value                  |
    |                    |
LiteralNode              |
  value -> 0             |
                         |
    +--------------------+
    |
MethodEndNode
  value
    |
SendNode
   func -> *
   arg[0] --------------+
   arg[1]               |
    |                   |
SendNode                |
   func -> fact         |
   arg[0]               |
    |                   |
SendNode                |
   func -> -            |
   arg[0] -----+        |
   arg[1]      |        |
    |          |        |
LiteralNode    |        |
  value -> 0   |        |
               |        |
    +----------+        |
    |                   |
LocalVarNode            |
  offset -> 0           |
  depth -> 0            |
                        |
    +-------------------+
    |
LocalVarNode            
  offset -> 0           
  depth -> 0            

=end

  module VM
    # Expression of VM is a set of Nodes
    module Node
      module TypeListWithSignature
        def type_list_initvar
          TypeUtil::TypeContainer.new
        end
        
        def type_list(sig)
          @type_list.type_list(sig).value
        end

        def set_type_list(sig, val, pos = 1)
          @type_list.type_list(sig).value[pos] = val
        end

        def add_type(sig, type, pos = 0)
          @type_list.add_type(sig, type, pos)
          if type.have_element? then
            if @my_element_node == nil then
              @my_element_node = BaseNode.new(self)
            end
            if @element_node_list == [] then
              @element_node_list = [[sig, @my_element_node, nil]]
            end
          end
        end
      end

      module TypeListWithoutSignature
        def type_list_initvar
          [[], []]
        end
        
        def type_list(sig)
          @type_list
        end

        def set_type_list(sig, val, pos = 1)
          @type_list[pos] = val
        end

        def add_type(sig, type, pos = 0)
          tvsv = @type_list[pos]
          if !tvsv.include? type then
            tvsv.push type
          end
          if type.have_element? then
            if @my_element_node == nil then
              @my_element_node = BaseNode.new(self)
            end
            if @element_node_list == [] then
              @element_node_list = [[sig, @my_element_node, nil]]
            end
          end
        end
      end
      
      class BaseNode
        include Inspect
        include AbsArch
        include TypeListWithSignature

        def initialize(parent)
          cs = CodeSpace.new
          asm = Assembler.new(cs)
          asm.with_retry do
            asm.mov(TMPR, 4)
            asm.ret
          end

          # iv for structure of VM
          @parent = parent
          @code_space = nil
          @id = nil
          if @parent then
            @id = @parent.id.dup
            @id[-1] = @id[-1] + 1
          else
            @id = [0]
          end

          # iv for type inference
          @type = nil
          @type_list = type_list_initvar
          @element_node_list = []
          @my_element_node = nil
          @type_inference_proc = cs
          @type_cache = nil
          @is_escape = false

          @ti_observer = {}
          @ti_observee = []

          @debug_info = nil
        end

        attr_accessor :parent
        attr          :code_space
        attr          :id

        attr_accessor :type
        attr_accessor :element_node_list
        attr_accessor :is_escape

        attr          :ti_observer
        attr          :ti_observee

        attr_accessor :debug_info

        def collect_info(context)
          if is_a?(HaveChildlenMixin) then
            traverse_childlen {|rec|
              context = rec.collect_info(context)
            }
          end

          context
        end

        def ti_add_observer(dst, dsig, ssig, context)
          if @ti_observer[dst] == nil then
            @ti_observer[dst] = []
            dst.ti_observee.push self
          end
          
          if @ti_observer[dst].all? {|edsig, essig, eprc| 
              (edsig != dsig) or (essig != ssig)
            } then
            prc = lambda { send(:ti_update, dst, self, dsig, ssig, context) }
            @ti_observer[dst].push [dsig, ssig, prc]
          end
        end

        def ti_changed
          @ti_observer.each do |rec, lst|
            lst.each do |dsig, ssig, prc|
              prc.call
            end
          end
        end

        def ti_reset(visitnode = {})
          if visitnode[self] then
            return
          end

          visitnode[self] = true
          @ti_observer.each do |rec, lst|
            lst.each do |dsig, ssig, prc|
              rec.type_list(dsig)[1] = []

              rec.ti_reset(visitnode)
            end
          end
        end

        def ti_del_link(visitnode = {})
          if visitnode[self] then
            return
          end

          visitnode[self] = true
          @ti_observer.each do |rec, lst|
            delent = []
            lst.each do |ent|
              delent.push ent
                
              rec.ti_del_link(visitnode)
            end

            delent.each do |ent|
              lst.delete(ent)
            end
          end
        end

        def merge_type(dst, src)
          res = dst
          src.each do |sele|
            if !res.include? sele then
              res.push sele
=begin
            elsif sele.have_element? and false then
              res.each do |dele|
                if dele == sele and dele.element_type == nil then
                  dele.element_type = sele.element_type
                end
              end
=end
            end
          end

          res
        end

        def ti_update(dst, src, dsig, ssig, context)
          dtlistorg = dst.type_list(dsig)
          dtlist = dtlistorg.flatten
          stlist = src.type_list(ssig).flatten
=begin
          print "UPDATE TYPE\n"
          print "#{src.class} #{ssig.inspect} -> #{dst.class} #{dsig.inspect}\n"
          print dtlist.map(&:ruby_type), "\n"
          print stlist.map(&:ruby_type), "\n"
=end
          orgsize = dtlist.size
#          pp "#{dst.class} #{src.class} #{dtlist} #{stlist}"
          newdt = merge_type(dtlistorg[1], stlist)
          dst.set_type_list(dsig, newdt)
          dtsize = dtlistorg[0].size + newdt.size

          if orgsize != dtsize then
            dst.type = nil
            dst.ti_changed
            context.convergent = false
          end

          dtlist = dst.element_node_list
          stlist = src.element_node_list
          orgsize = dtlist.size
          dst.element_node_list = merge_type(dtlist, stlist)
          if orgsize != dtlist.size then
            dst.ti_changed
            context.convergent = false
          end

          if src.is_escape then
            if dst.is_escape != true then
              dst.is_escape = src.is_escape
            end
          end
        end

        def same_type(dst, src, dsig, ssig, context)
=begin
          print "#{src.class} -> #{dst.class} \n"
          if dst.is_a?(LocalVarNode) then
            print "#{dst.name} \n"
          end
          if dst.is_a?(LiteralNode) then
            print "#{dst.value.inspect} \n"
          end
          if dst.is_a?(SendNode) then
            print "#{dst.func.name} \n"
          end
=end

          if dst.is_a?(BaseNode) then
            src.ti_add_observer(dst, dsig, ssig, context)
          end

          ti_update(dst, src, dsig, ssig, context)
        end

        def add_element_node_backward(args, visitnode = {})
          if visitnode[self] then
            return
          end

          add_element_node(*args)
          visitnode[self] = true
          @ti_observee.each do |rec|
            rec.add_element_node_backward(args, visitnode)
          end
        end

        def set_escape_node_backward(value = true, visitnode = {})
          if visitnode[self] then
            return
          end

          if @is_escape != true then
            @is_escape = value
          end
          visitnode[self] = true
          @ti_observee.each do |rec|
            rec.set_escape_node_backward(value, visitnode)
          end
        end

        def add_element_node(sig, enode, index, context)
          slfetnode = @element_node_list
          unless slfetnode.include?([sig, enode, index])
            if @element_node_list == [] then
              @element_node_list.push [sig, enode, nil]
            end
            newele = [sig, enode, index]
            if !@element_node_list.include?(newele)
              @element_node_list.push newele
              orgsig = @element_node_list[0][0]
              orgnode = @element_node_list[0][1]
              if orgnode != enode then
                same_type(orgnode, enode, orgsig, sig, context)
              end
              if index != nil then
                @element_node_list.each do |orgsig, orgnode, orgindex|
                  if orgindex == index and
                      orgnode != enode then
                    # same_type(orgnode, enode, orgsig, sig, context)
                  end
                end
              end
            end
                  
            ti_changed
#            context.convergent = false
          end
        end

        def collect_candidate_type(context)
          raise "You must define collect_candidate_type per node"
          context
        end

        def decide_type_core(tlist, local_cache = {})
          tlist = tlist.select {|e| e.class != RubyType::DefaultType0 }

          # This is for sitration of same class and differenc element type.
          # Last element must be local type not propageted type
          if tlist.size > 1 and tlist.all? {|e| 
              e.ruby_type == tlist[0].ruby_type 
            } then
            return tlist.last
          end

          case tlist.size
          when 0
            RubyType::DefaultType0.new
            
          when 1
            local_cache[self] = tlist[0]
            if tlist[0].have_element? then
              etype = {}
              @element_node_list.each do |ele|
                sig = ele[0]
                node = ele[1]
                tt = node.decide_type_once(sig, local_cache)
                etype[ele[2]] ||= []
                curidx = etype[ele[2]]
                if !curidx.include?(tt) then
                  curidx.push tt
                end
              end
              tlist[0].element_type = etype
            end
            tlist[0]

          when 2
            if tlist[0].ruby_type == tlist[1].ruby_type then
              if tlist[0].abnormal? then
                tlist[0]
              else
                tlist[1]
              end

            elsif tlist[0].ruby_type == Float and
                tlist[1].ruby_type == Fixnum then
              tlist[0]

            elsif tlist[0].ruby_type == Fixnum and
                tlist[1].ruby_type == Float then
              tlist[1]

            else 
              RubyType::DefaultType0.new
            end

          else
            RubyType::DefaultType0.new
          end
        end

        def decide_type_once(sig, local_cache = {})
          if local_cache[self] then
            return local_cache[self] 
          end

          if @type.equal?(nil) or @type.is_a?(RubyType::DefaultType0) then
            tlist = type_list(sig).flatten.uniq
            @type = decide_type_core(tlist, local_cache)
          end

          @type
        end

        def decide_type(sig)
          decide_type_once(sig)

          if is_a?(HaveChildlenMixin) then
            traverse_childlen {|rec|
              rec.decide_type(sig)
            }
          end
        end

        def inference_type
          cs = @type_inference_proc
          cs.call(cs.var_base_address)
        end

        def gen_type_inference_proc(code)
        end

        def compile(context)
          @code_space = context.code_space
          context
        end

        def get_constant_value
          nil
        end
      end
      
      module HaveChildlenMixin
        def initialize(*args)
          super
          @body = DummyNode.new
        end

        attr_accessor :body

        def traverse_childlen
          raise "You must define traverse_childlen #{self.class}"
        end
      end

      module NodeUtil
        def search_class_top
          cnode = @parent

          # ClassTopNode include TopTopNode
          while !cnode.is_a?(ClassTopNode)
            cnode = cnode.parent
          end

          cnode
        end

        def search_top
          cnode = @parent

          # ClassTopNode include TopTopNode
          while !cnode.is_a?(TopNode)
            cnode = cnode.parent
          end

          cnode
        end

        def search_end
          cnode = @parent

          # ClassTopNode include TopTopNode
          while !cnode.is_a?(MethodEndNode)
            cnode = cnode.body
          end

          cnode
        end

        def search_frame_info
          cnode = @parent

          # ClassTopNode include TopTopNode
          while !cnode.is_a?(LocalFrameInfoNode)
            cnode = cnode.parent
          end

          cnode
        end
      end

      module SendUtil
        include AbsArch

        def gen_eval_self(context)
          # eval 1st arg(self)
          slfnode = @arguments[2]
          context = slfnode.compile(context)
          
          context.ret_node.decide_type_once(context.to_signature)
          rtype = context.ret_node.type
          if !rtype.boxed then
            context = rtype.gen_unboxing(context)
          end
          context
        end

        def signature(context, args = @arguments)
          res = []
          cursig = context.to_signature
          args[0].decide_type_once(cursig)
          res.push args[0].type

          mt, slf = get_send_method_node(cursig)
          if mt and (ynode = mt.yield_node[0]) then
            context.push_signature(args, mt)
            args[1].type = nil
            args[1].decide_type_once(ynode.signature(context))
            res.push args[1].type
            context.pop_signature
          else
            args[1].decide_type_once(cursig)
            res.push args[1].type
            args[2].decide_type_once(cursig)
            slf = args[2].type
          end
          res.push slf

          args[3..-1].each do |ele|
            ele.decide_type_once(cursig)
            res.push ele.type
          end

          res
        end

        def compile_c_vararg(context)
          fnc = nil
          context.start_using_reg(TMPR2)
          
          context = gen_make_argv(context) do |context, rarg|
            context.start_arg_reg
            
            context.cpustack_pushn(3 * AsmType::MACHINE_WORD.size)
            casm = context.assembler
            casm.with_retry do 
              casm.mov(FUNC_ARG[0], rarg.size) # argc
              casm.mov(FUNC_ARG[1], TMPR2)     # argv
            end
            context.set_reg_content(FUNC_ARG[0].dst_opecode, nil)
            context.set_reg_content(FUNC_ARG[1].dst_opecode, TMPR2)

            # Method Select
            # it is legal. use TMPR2 for method select
            # use PTMPR for store self
            context = @func.compile(context)
            fnc = context.ret_reg
            casm.with_retry do 
              casm.mov(FUNC_ARG[2], context.ret_reg2)     # self
            end
            context.set_reg_content(FUNC_ARG[2].dst_opecode, context.ret_node)
            
            context = gen_save_thepr(context)
            context = gen_call(context, fnc, 3)
            context.cpustack_popn(3 * AsmType::MACHINE_WORD.size)
            context.end_arg_reg
            context.end_using_reg(TMPR2)
            context.ret_reg = RETR
            context.set_reg_content(context.ret_reg, self)
            context.ret_node = self
            
            decide_type_once(context.to_signature)
            if !@type.boxed then 
              context = @type.to_box.gen_unboxing(context)
            end
            
            context
          end
        end

        def compile_c_fixarg(context)
          fnc = nil
          numarg = @arguments.size - 2
          
          context.start_arg_reg
          context.cpustack_pushn(numarg * AsmType::MACHINE_WORD.size)
          
          argpos = 0
          cursrc = 0
          @arguments.each do |arg|
            # skip prevenv and block_argument
            if cursrc < 2 then
              cursrc = cursrc + 1
              next
            end
            
            if cursrc == 2 then
              # Self
              # Method Select
              # it is legal. use TMPR2 for method select
              # use PTMPR for store self
              context = @func.compile(context)
              fnc = context.ret_reg
              casm = context.assembler
              casm.with_retry do 
                casm.mov(FUNC_ARG[0], context.ret_reg2)
              end
              context.set_reg_content(FUNC_ARG[0].dst_opecode, 
                                      context.ret_node)
            else
              # other arg.
              context = arg.compile(context)
              context.ret_node.decide_type_once(context.to_signature)
              rtype = context.ret_node.type
              context = rtype.gen_boxing(context)
              casm = context.assembler
              casm.with_retry do 
                casm.mov(FUNC_ARG[argpos], context.ret_reg)
              end
              context.set_reg_content(FUNC_ARG[argpos].dst_opecode, 
                                      context.ret_node)
            end
            argpos = argpos + 1
            cursrc = cursrc + 1
          end
          
          context = gen_save_thepr(context)
          context = gen_call(context, fnc, numarg)
          
          context.cpustack_popn(numarg * AsmType::MACHINE_WORD.size)
          context.end_arg_reg
          context.end_using_reg(fnc)
          context.ret_reg = RETR
          context.set_reg_content(context.ret_reg, self)
          
          decide_type_once(context.to_signature)
          if !@type.boxed then 
            context = @type.to_box.gen_unboxing(context)
          end
          
          context
        end

        def compile_ytl(context)
          fnc = nil
          numarg = @arguments.size
          
          context.start_arg_reg
          context.start_arg_reg(FUNC_ARG_YTL)
          context.cpustack_pushn(numarg * 8)
          
          # push prev env
          casm = context.assembler
          if @func.is_a?(YieldNode) then
            prevenv = @frame_info.offset_arg(0, BPR)
            casm.with_retry do 
              casm.mov(TMPR, prevenv)
              casm.mov(FUNC_ARG_YTL[0], TMPR)
            end
            context.set_reg_content(FUNC_ARG_YTL[0].dst_opecode, prevenv)
          else
            casm.with_retry do 
              casm.mov(FUNC_ARG_YTL[0], BPR)
            end
            context.set_reg_content(FUNC_ARG_YTL[0].dst_opecode, BPR)
          end
          
          # block
          # eval block
          # local block
          
          # compile block with other code space and context
          tcontext = context.dup
          tcontext.prev_context = context
          @arguments[1].compile(tcontext)
          
          casm = context.assembler

          # other arguments
          @arguments[3..-1].each_with_index do |arg, i|
            context = arg.compile(context)
            casm = context.assembler
            casm.with_retry do 
              casm.mov(FUNC_ARG_YTL[i + 3], context.ret_reg)
            end
            context.set_reg_content(FUNC_ARG_YTL[i + 3].dst_opecode, 
                                    context.ret_node)
          end
          
          casm.with_retry do 
            entry = @arguments[1].code_space.var_base_immidiate_address
            casm.mov(FUNC_ARG_YTL[1], entry)
          end
          context.set_reg_content(FUNC_ARG_YTL[1].dst_opecode, nil)

          # self
          # Method Select
          # it is legal. use TMPR2 for method select
          # use PTMPR for store self
          context = @func.compile(context)
          fnc = context.ret_reg
          casm = context.assembler
          casm.with_retry do 
            casm.mov(FUNC_ARG_YTL[2], context.ret_reg2)
          end
          context.set_reg_content(FUNC_ARG_YTL[2].dst_opecode, @arguments[2])

          context = gen_call(context, fnc, numarg)
          
          context.cpustack_popn(numarg * 8)
          context.end_arg_reg
          context.end_arg_reg(FUNC_ARG_YTL)
          context.end_using_reg(fnc)
          context
        end

        def compile_c_fixarg_raw(context)
          context = @func.compile(context)
          fnc = context.ret_reg
          numarg = @arguments.size
          
          context.start_arg_reg
          context.cpustack_pushn(numarg * AsmType::MACHINE_WORD.size)
          
          @arguments.each_with_index do |arg, argpos|
#            p "#{@func.name} #{argpos}"
            context = arg.compile(context)
            rtype = context.ret_node.decide_type_once(context.to_signature)

            atype = @func.arg_type[argpos]
            if atype == :"..." or atype == nil then
              if @func.arg_type.last == :"..." then
                atype = @func.arg_type[-2]
              end
            end
            if atype == :VALUE then
              context = rtype.gen_boxing(context)
            end

            casm = context.assembler
            casm.with_retry do 
              casm.mov(FUNC_ARG[argpos], context.ret_reg)
            end
            context.set_reg_content(FUNC_ARG[argpos].dst_opecode, 
                                    context.ret_node)
          end
          
          context = gen_save_thepr(context)
          context = gen_call(context, fnc, numarg)
          
          context.cpustack_popn(numarg * AsmType::MACHINE_WORD.size)
          context.end_arg_reg
          context.end_using_reg(fnc)
          context.ret_reg = RETR
          context.set_reg_content(context.ret_reg, self)
          
          decide_type_once(context.to_signature)
          context
        end
      end

      module MultipleCodeSpaceUtil
        def find_cs_by_signature(sig)
          @code_spaces.each do |csig, val|
            if csig == sig then
              return val
            end
          end

          nil
        end

        def add_cs_for_signature(sig)
          cs = find_cs_by_signature(sig)
          if cs then
            return nil

          else
            cs = CodeSpace.new
            @code_spaces.push [sig, cs]
            return cs
          end
        end

        def get_code_space(sig)
          cs = find_cs_by_signature(sig)
          if cs == nil then
            cs = CodeSpace.new
            @code_spaces.push [sig, cs]
          end
          cs
        end
      end

      class DummyNode
        def collect_info(context)
          context
        end

        def collect_candidate_type(context)
          context
        end

        def compile(context)
          # Not need super because this is dummy
          context
        end
      end

      # The top of top node
      class TopNode<BaseNode
        include HaveChildlenMixin
        include NodeUtil
        include MultipleCodeSpaceUtil
        
        def initialize(parent, name = nil)
          super(parent)
          @name = name
          @code_spaces = [] # [[nil, CodeSpace.new]]
          @orig_modified_local_var = []
          @yield_node = []
          if @parent then
            @classtop = search_class_top
          else
            @classtop = self
          end
          @end_nodes = []
          @signature_cache = []
          @exception_table = nil
        end

        attr_accessor :name
        attr          :end_nodes
        attr          :orig_modified_local_var
        attr          :yield_node

        attr          :signature_cache
        attr_accessor :exception_table

        def modified_instance_var
          search_end.modified_instance_var
        end

        def traverse_childlen
          yield @body
        end

        def add_arg_to_args(args, addnum)
          if args.is_a?(Integer) then
            args = args + addnum
          elsif args.is_a?(Array) then
            args = args.dup
            args[0] += addnum
            args[3] += addnum if args[3] >= 0
            args[4] += addnum if args[4] >= 0
            args[5] += addnum if args[5] >= 0
          else
            raise "Unkonwn args #{args}"
          end

          args
        end

        def construct_frame_info(locals, argnum, args)
          finfo = LocalFrameInfoNode.new(self)
          finfo.system_num = 5         # BP ON Stack, HP, ET, BP, RET

          argc = args
          opt_label = []
          rest_index = -1
          post_len = -1
          post_start = -1
          block_index = -1
          simple = -1
          if args.is_a?(Array) then
            argc = args[0]
            opt_label = args[1]
            post_len = args[2]
            post_start = args[3]
            rest_index = args[4]
            block_index = args[5]
            simple = args[6]
          end
          
          # 5means BP, HP, Exception Tag, BP and SP
          lsize = locals.size + finfo.system_num
          
          # construct frame
          frame_layout = Array.new(lsize)
          fargstart = lsize - argnum
          i = 0
          argnum.times do
            kind = :arg
            if i == rest_index then
              kind = :rest_arg
            end
            lnode = LocalVarNode.new(finfo, locals[i], fargstart + i,
                                     kind)
            frame_layout[fargstart + i] = lnode
            i = i + 1
          end
          
          curpos = fargstart - 1
          frame_layout[curpos] = SystemValueNode.new(finfo, 
                                                     :RET_ADDR, curpos)
          curpos -= 1
          frame_layout[curpos] = SystemValueNode.new(finfo, 
                                                     :OLD_BP, curpos)
          curpos -= 1
          frame_layout[curpos] = SystemValueNode.new(finfo, 
                                                     :EXPTAG, curpos)
          curpos -= 1
          frame_layout[curpos] = SystemValueNode.new(finfo, 
                                                     :TMPHEAP, curpos)
          curpos -= 1
          frame_layout[curpos] = SystemValueNode.new(finfo, 
                                                     :OLD_BPSTACK, curpos)

          j = 0
          lvarnum = lsize - finfo.system_num 
          while i < lvarnum do
            lnode = LocalVarNode.new(finfo, locals[i], j, :local_var)
            frame_layout[j] = lnode
            i += 1
            j += 1
          end
          finfo.frame_layout = frame_layout
          finfo.argument_num = argnum
          
          @body = finfo
          finfo.init_after_construct
          finfo
        end

        def collect_info(context)
          context.yield_node.push []
          context = @body.collect_info(context)
          @yield_node = context.yield_node.pop
          if @exception_table then
            @exception_table.each do |kind, lst|
              lst.each do |st, ed, cnt, body|
                if body then
                  context = body.collect_info(context)
                end
              end
            end
          end
          context
        end

        def collect_candidate_type(context, signode, sig)
          if add_cs_for_signature(sig) == nil and  
              context.visited_top_node[self] then
            return context
          end

          context.visited_top_node[self] = true

          if !@signature_cache.include?(sig) then
            @signature_cache.push sig
          end
          
          context.push_signature(signode, self)
          context = @body.collect_candidate_type(context)

          if @exception_table then
            @exception_table.each do |kind, lst|
              lst.each do |st, ed, cnt, body|
                if body then
                  context = body.collect_candidate_type(context)
                end
              end
            end
          end
          context.pop_signature

          @end_nodes.each do |enode|
            same_type(self, enode, sig, sig, context)
            same_type(enode, self, sig, sig, context)
          end
          context
        end

        def disp_signature
          tcontext = CompileContext.new(self)
          print "#{@classtop.klass_object}##{@name} "
          @code_spaces.each do |sig, cs|
            print sig, " -> "
            tl = type_list(sig).flatten.uniq
            print decide_type_core(tl).inspect, "\n"
            pp tl
#            print "CodeSpace 0x#{cs.base_address.to_s(16)}\n"
            print "CodeSpace #{cs.inspect}\n"
          end
        end

        def compile_init(context)
          context
        end

        def compile(context)
          oldcs = context.code_space
          @code_spaces.each do |sig, cs|
            context.current_method_signature.push sig
            context.set_code_space(cs)
            context = super(context)
            context.reset_using_reg
            context = gen_method_prologue(context)
            context = compile_init(context)
            context = @body.compile(context)

            if @exception_table then
              @exception_table.each do |kind, lst|
                lst.each do |st, ed, cnt, body|
                  if body then
                    context = body.compile(context)
                  end
                end
              end
            end
            context.current_method_signature.pop
          end

          if oldcs then
            context.set_code_space(oldcs)
          end

          if context.options[:disp_signature] then
            disp_signature
          end

          context.ret_node = self
          context
        end
      end

      # Top of method definition
      class MethodTopNode<TopNode
        include MethodTopCodeGen

        def collect_info(context)
          context.modified_local_var.push [{}]
          context = super
          context.modified_local_var.pop
          context
        end

        def construct_frame_info(locals, argnum, args)
          locals.unshift :_self
          locals.unshift :_block
          locals.unshift :_prev_env
          argnum += 3
          args = add_arg_to_args(args, 3)
          super(locals, argnum, args)
        end
      end

      class BlockTopNode<MethodTopNode
        def collect_info(context)
          @orig_modified_local_var = context.modified_local_var.last.map {|e|
            e.dup
          }
          context.modified_local_var.last.push Hash.new
          context = @body.collect_info(context)
          context.modified_local_var.last.pop
          context
        end

        include MethodTopCodeGen
      end

      class ClassTopNode<TopNode
        include SendNodeCodeGen
        include MethodTopCodeGen
        @@class_top_tab = {}

        def self.get_class_top_node(klass)
          @@class_top_tab[klass]
        end

        def initialize(parent, klassobj, name = nil)
          super(parent, name)
          @constant_tab = {}
          @method_tab = {}
          @klass_object = klassobj
          @klassclass = ClassClassWrapper.instance(@klass_object)
          @klassclass_node = nil # Lazy
          RubyType::define_wraped_class(@klassclass, 
                                        RubyType::RubyTypeBoxed)
          unless @@class_top_tab[klassobj]
            @@class_top_tab[klassobj] = self
          end
        end

        attr :klass_object
        attr :constant_tab
        attr :method_tab
        attr :klassclass
        attr :klassclass_node

        def collect_info(context)
          context.modified_local_var.push [{}]
          context.modified_instance_var = Hash.new
          context = super
          context.modified_local_var.pop
          if @klassclass_node then
            @klassclass_node.collect_info(context)
          else
            context
          end
        end

        def make_klassclass_node
          if @klassclass_node == nil then
            clsclsnode = ClassTopNode.new(self, 
                                          @klassclass, 
                                          @klassclass.name)
            clsclsnode.body = DummyNode.new
            @klassclass_node = clsclsnode
          end
        end

        def get_method_tab(klassobj = @klass_object)
          ktop =  @@class_top_tab[klassobj]
          if ktop then
            ktop.method_tab
          else
            {}
          end
        end

        def get_constant_tab(klassobj = @klass_object)
          ktop =  @@class_top_tab[klassobj]
          if ktop then
            ktop.constant_tab
          else
            ktop.constant_tab = {}
            ktop.constant_tab
          end
        end

        def search_method_with_super(name, klassobj = @klass_object)
          clsnode = @@class_top_tab[klassobj]
          if clsnode then
            mtab = clsnode.get_method_tab
            if val = mtab[name] then
              return [val, clsnode]
            end
            
            return search_method_with_super(name, klassobj.superclass)
          end

          [nil, nil]
        end

        def search_constant_with_super(name, klassobj = @klass_object)
          clsnode = @@class_top_tab[klassobj]
          if clsnode then
            ctab = clsnode.get_constant_tab
            if val = ctab[name] then
              return [val, clsnode]
            end
            
            return search_constant_with_super(name, klassobj.superclass)
          end

          [nil, nil]
        end

        def construct_frame_info(locals, argnum, args)
          locals.unshift :_self
          locals.unshift :_block
          locals.unshift :_prev_env
          argnum += 3
          args = add_arg_to_args(args, 3)
          super(locals, argnum, args)
        end

        def collect_candidate_type(context, signode, sig)
          @type = RubyType::BaseType.from_ruby_class(@klassclass)
          add_type(sig, @type)

          if add_cs_for_signature(sig) == nil and  
              context.visited_top_node[self] then
            return context
          end

          context.visited_top_node[self] = true
          
          context.push_signature(signode, self)
          context = @body.collect_candidate_type(context)
          context.pop_signature

          if @klassclass_node then
            @klassclass_node.collect_candidate_type(context, signode, sig)
          else
            context
          end
        end

        def compile(context)
          context = super(context)

          sig = context.to_signature.dup
          sig[2] = @type
=begin
          pp sig
          pp @name
          pp @code_spaces.map{|a| a[0]}
=end

          cs = self.find_cs_by_signature(sig)
          if cs then
            asm = context.assembler
            add = lambda { @klass_object.address }
            var_klassclass = OpVarImmidiateAddress.new(add)
            context.start_arg_reg
            asm.with_retry do
              asm.mov(FUNC_ARG_YTL[0], BPR)
              asm.mov(FUNC_ARG_YTL[1], 4)
              asm.mov(FUNC_ARG_YTL[2], var_klassclass)
            end
            context.set_reg_content(FUNC_ARG_YTL[0].dst_opecode, BPR)
            context.set_reg_content(FUNC_ARG_YTL[1].dst_opecode, nil)
            context.set_reg_content(FUNC_ARG_YTL[2].dst_opecode, self)
            add = cs.var_base_address
            context = gen_call(context, add, 3)
            context.end_arg_reg
          end
          
          context
        end

        def get_constant_value
          [@klass_object]
        end
      end

      class TopTopNode<ClassTopNode
        include MethodTopCodeGen
        @@frame_struct_tab = {}
        @@local_object_area = Runtime::Arena.new

        def self.get_frame_struct_tab
          @@frame_struct_tab
        end

        def initialize(parent, klassobj, name = :top)
          super
          
          @code_space_tab = []
          @asm_tab = {}
          @id.push 0

          @frame_struct_array = []
          @unwind_proc = CodeSpace.new
          @init_node = nil
          init_unwind_proc
          add_code_space(nil, @unwind_proc)

          # Dummy for marshal
          @op_var_value_instaces = nil
        end

        attr_accessor :init_node
        attr          :code_space_tab
        attr          :asm_tab
        attr          :frame_struct_array

        def make_frame_struct_tab
          @frame_struct_array.each do |vkey, val|
            @@frame_struct_tab[vkey.value] = val
          end
        end

        def traverse_childlen
          if @init_node then
            yield @init_node
          end
          yield @body
        end

        def init_unwind_proc
          asm = Assembler.new(@unwind_proc)
          # Make linkage of frame pointer
          finfo = OpIndirect.new(TMPR3, AsmType::MACHINE_WORD.size * 2)
          retadd = OpIndirect.new(TMPR3, AsmType::MACHINE_WORD.size)
          asm.with_retry do
            asm.mov(TMPR3, BPR)
            asm.mov(TMPR3, INDIRECT_TMPR3)
            asm.mov(TMPR, finfo)
            asm.mov(TMPR3, INDIRECT_TMPR3)
            asm.mov(TMPR2, retadd) # Return address store by call inst.
            asm.ret
          end
        end
        
        def add_code_space(oldcs, newcs)
          if !@code_space_tab.include?(newcs) then
            @code_space_tab.push newcs
          end
        end

        def collect_info(context)
          if @init_node then
            context = @init_node.collect_info(context)
          end
          super(context)
        end

        def collect_candidate_type(context, signode, sig)
          context.convergent = true
          context.visited_top_node = {}
          if @init_node then
            context = @init_node.collect_candidate_type(context, signode, sig)
          end
          super(context, signode, sig)
        end

        def get_arena_address
          ar = @@local_object_area
          # 2 means used and size
          ar.raw_address
        end

        def get_arena_end_address
          ar = @@local_object_area
          (ar.body_address + ar.size) & (~0xf)
        end

        def compile_init(context)
          addr = lambda {
            get_arena_end_address
          }
          aa = OpVarImmidiateAddress.new(addr) 
          asm = context.assembler
          asm.with_retry do
            asm.mov(THEPR, aa)
          end
          context
        end

        def compile(context)
          if @init_node then
            context = @init_node.compile(context)
          end
          super(context)
        end

        def code_store_hook
          @op_var_value_instaces = OpVarValueMixin.instances
        end

        def update_after_restore
          @op_var_value_instaces.each do |ins|
            ins.refer.each do |stfn|
              stfn.call
            end
          end
        end
      end

      class ExceptionTopNode<TopNode
        include HaveChildlenMixin
        include NodeUtil
        include MultipleCodeSpaceUtil

        def initialize(parent, name = nil)
          super
          @code_spaces = []
        end

        def collect_info(context)
          @body.collect_info(context)
        end

        def collect_candidate_type(context)
          @body.collect_candidate_type(context)
        end

        def compile(context)
          sig = context.to_signature
          cs = get_code_space(sig)
          oldcs = context.set_code_space(cs)
          context = @body.compile(context)
          context.set_code_space(oldcs)
          context
        end
      end

      class LocalFrameInfoNode<BaseNode
        include HaveChildlenMixin
        
        def initialize(parent)
          super(parent)
          @frame_layout = []
          @argument_num = nil
          @system_num = nil
          @previous_frame = search_previous_frame(parent)
          @offset_cache = {}
          @local_area_size = nil
          @alloca_area_size = 0
        end

        def init_after_construct
          @local_area_size = compute_local_area_size
        end

        def search_previous_frame(mtop)
          cnode = mtop.parent
          while !cnode.is_a?(TopNode)
            if cnode then
              cnode = cnode.parent
            else
              return nil
            end
          end

          return cnode.body
        end

        def copy_frame_layout
          @frame_layout.each { |ele| ele.dup }
        end

        attr_accessor :frame_layout
        attr_accessor :argument_num
        attr_accessor :system_num
        attr          :previous_frame

        def traverse_childlen
          @frame_layout.each do |vinf|
            yield vinf
          end
          yield @body
        end

        def frame_size
          @frame_layout.inject(0) {|sum, slot| sum += slot.size}
        end

        def compute_local_area_size
          localnum = @frame_layout.size - @argument_num - @system_num
          @frame_layout[0, localnum].inject(0) {|sum, slot| 
            sum += slot.size
          }
        end

        def real_offset(off)
          if off >=  @argument_num then
            off = off - @argument_num
          else
            off = off + (@frame_layout.size - @argument_num)
          end

          off
        end

        def offset_by_byte(off)
          off = real_offset(off)

          obyte = 0
          off.times do |i|
            obyte += @frame_layout[i].size
          end
          
          obyte - @local_area_size
        end

        def offset_arg(n, basereg)
          rc = nil
          if basereg == BPR then
            rc = @offset_cache[n]
            unless rc
              off = offset_by_byte(n)
              rc = @offset_cache[n] = OpIndirect.new(basereg, off)
            end
          else
            off = offset_by_byte(n)
            rc = OpIndirect.new(basereg, off)
          end

          rc
        end

        def static_alloca(size)
#          base = -offset_by_byte(0)
          @alloca_area_size += size
          -(@local_area_size + @alloca_area_size)
        end

        def collect_candidate_type(context)
          traverse_childlen {|rec|
            context = rec.collect_candidate_type(context)
          }
        end

        def compile(context)
          context = super(context)
          siz = @local_area_size + @alloca_area_size
          if  siz != 0 then
            asm = context.assembler
            asm.with_retry do
              asm.sub(SPR, siz)
            end
          end
          context.cpustack_pushn(siz)
          context = @body.compile(context)
          context.cpustack_popn(siz)
          context
        end
      end

      class LocalVarNode<BaseNode
        def initialize(parent, name, offset, kind)
          super(parent)
          @name = name
          @offset = offset
          @kind = kind
        end

        attr :name
        attr :kind

        def size
          8
        end

        def collect_info(context)
          flay = @parent.frame_layout
          fragstart = flay.size - @parent.argument_num
          if fragstart <= @offset then
            argoff = @offset - fragstart
          else
            argoff = @offset + @parent.argument_num
          end
=begin
          # Assertion check for reverse of real_offset
          unless @offset == @parent.real_offset(argoff)
            raise
          end
=end
          topnode = @parent.parent
          context.modified_local_var.last.last[argoff] = [[topnode, self]]
          context
        end

        def collect_candidate_type(context)
          flay = @parent.frame_layout
          fragstart = flay.size - @parent.argument_num
          if fragstart <= @offset then
            argoff = @offset - fragstart
            tobj = context.current_method_signature_node.last[argoff]
            cursig = context.to_signature
            cursig2 = context.to_signature(-2)
            if tobj then
              same_type(self, tobj, cursig, cursig2, context)
              same_type(tobj, self, cursig2, cursig, context)
            end
          end
          context
        end

        def compile(context)
          context = super(context)
          context
        end
      end

      class SystemValueNode<BaseNode
        def initialize(parent, kind, offset)
          super(parent)
          @kind = kind
          @offset = offset
        end

        attr :offset

        def collect_candidate_type(context)
          context
        end

        def size
          AsmType::MACHINE_WORD.size
        end

        def compile(context)
          context = super(context)
          context
        end
      end

      # Guard (type information holder and type checking of tree)
      class GuardNode<BaseNode
        include HaveChildlenMixin
      end

      # End of method definition
      class MethodEndNode<BaseNode
        include MethodEndCodeGen

        def initialize(parent)
          super(parent)
          @modified_instance_var = nil
        end

        attr :modified_instance_var

        def collect_info(context)
          @modified_instance_var = context.modified_instance_var
          context
        end

        def collect_candidate_type(context)
          cursig = context.to_signature
          same_type(self, @parent, cursig, cursig, context)
          same_type(@parent, self, cursig, cursig, context)
          context
        end

        def compile(context)
          context = super(context)
          context = gen_method_epilogue(context)
          curas = context.assembler
          curas.with_retry do
            curas.ret
          end
          context
        end
      end

      class BlockEndNode<MethodEndNode
        include MethodEndCodeGen
      end

      class ClassEndNode<MethodEndNode
        include MethodEndCodeGen

        def initialize(parent)
          super(parent)
          @modified_instance_var = nil
        end

        attr :modified_instance_var

        def collect_info(context)
          @modified_instance_var = context.modified_instance_var
          context
        end
      end

      # Set result of method/block
      class SetResultNode<BaseNode
        include HaveChildlenMixin

        def initialize(parent, valnode)
          super(parent)
          @value_node = valnode
        end

        attr :value_node

        def traverse_childlen
          yield @value_node
          yield @body
        end

        def collect_candidate_type(context)
          context = @value_node.collect_candidate_type(context)
          cursig = context.to_signature
          same_type(self, @value_node, cursig, cursig, context)
          same_type(@value_node, self, cursig, cursig, context)

          rtype = decide_type_once(cursig)
          rrtype = rtype.ruby_type
          if !rtype.boxed and rrtype != Fixnum and rrtype != Float then
            set_escape_node_backward(:export_object)
          else
            set_escape_node_backward(:not_export)
          end
          @body.collect_candidate_type(context)
        end

        def compile(context)
          context = super(context)
          context = @value_node.compile(context)
          if context.ret_reg != RETR then
            if context.ret_reg.is_a?(OpRegXMM) then
=begin
                 decide_type_once(context.to_signature)
                 context = @type.gen_boxing(context)
                 if context.ret_reg != RETR then
                   curas = context.assembler
                   curas.with_retry do
                    curas.mov(RETR, context.ret_reg)
                  end
                   
                   context.set_reg_content(RETR, context.ret_node)
                 end
=end
              context.set_reg_content(context.ret_reg, context.ret_node)
            else
              curas = context.assembler
              curas.with_retry do
                curas.mov(RETR, context.ret_reg)
              end
              context.set_reg_content(RETR, context.ret_node)
              context.ret_reg = RETR
            end
          else
            context.set_reg_content(RETR, context.ret_node)
            context.ret_reg = RETR
          end

          @body.compile(context)
        end
      end

      class PhiNode<BaseNode
        def initialize(parent)
          super(parent)
          @local_label = parent
        end
        
        def collect_candidate_type(context)
          @local_label.come_from.values.each do |vnode|
            if vnode then
              cursig = context.to_signature
              same_type(self, vnode, cursig, cursig, context)
            end
          end
          context
        end

        def compile(context)
          context = super(context)
          context.ret_node = self
          context.ret_reg = @local_label.res_area
          context
        end
      end

      class LocalLabel<BaseNode
        include HaveChildlenMixin
        include NodeUtil
        include MultipleCodeSpaceUtil

        def initialize(parent, name)
          super(parent)
          @name = name
          @come_from = {}
          @come_from_val = []
          @current_signature = nil
          @code_spaces = []
          @value_node = nil
          @modified_local_var_list = []
          @res_area = nil
        end

        attr          :name
        attr          :come_from
        attr_accessor :value_node
        attr          :res_area

        def traverse_childlen
          yield @value_node
          yield @body
        end

        def lonly_node(node)
          while !node.is_a?(TopNode) 
            if node.is_a?(LocalLabel) then
              if node.come_from.size == 0 then
                return true
              else
                return false
              end
            end

            node = node.parent
          end

          return false
        end

        def collect_info(context)
          if @modified_local_var_list.size == 0 then
            # first visit
            delnode = []
            fornode = []
            @come_from.keys.each do |ele|
              if lonly_node(ele) then
                delnode.push ele
              end
            end
            delnode.each do |ele|
              @come_from.delete(ele)
            end
          end
            
          modlocvar = context.modified_local_var.last.map {|ele| ele.dup}
          @modified_local_var_list.push modlocvar
          if @modified_local_var_list.size == 1 then
            tnode = search_frame_info
            offset = tnode.static_alloca(8)
            @res_area = OpIndirect.new(BPR, offset)
            @body.collect_info(context)
          elsif @modified_local_var_list.size == @come_from.size then
            context.merge_local_var(@modified_local_var_list)
            @body.collect_info(context)
          else
            context
          end
        end

        def compile_block_value(context, comefrom)
          valnode = @come_from[comefrom]
          if valnode then
            context = valnode.compile(context)
            asm = context.assembler
            if !context.ret_reg.is_a?(OpRegXMM) then
              asm.with_retry do
                asm.mov(TMPR, context.ret_reg)
                asm.mov(@res_area, TMPR)
              end
              context.ret_reg = TMPR
            end
          end

          context.set_reg_content(context.ret_reg, self)
          context
        end

        def traverse_block_value(comefrom, &block)
          valnode = @come_from[comefrom]
          if valnode then
            yield valnode
          else
            nil
          end
        end

        def collect_candidate_type(context, sender = nil)
           if @come_from.keys[0] == sender then
             @body.collect_candidate_type(context)
          else
            context
          end
       end

        def compile(context)
          context = super(context)
          if @current_signature == nil or
              @current_signature != context.to_signature then
            @come_from_val = []
            @current_signature = context.to_signature
          end

          @come_from_val.push context.ret_reg
          
          if @come_from_val.size == 1 then
            @body.compile(context)
          else
            context
          end
        end
      end

      class BranchCommonNode<BaseNode
        include HaveChildlenMixin
        include IfNodeCodeGen

        def initialize(parent, cond, jmpto)
          super(parent)
          @cond = cond
          @jmp_to_node = jmpto
        end

        def traverse_childlen(&block)
          @jmp_to_node.traverse_block_value(self, &block)
          yield @cond
          yield @jmp_to_node
          yield @body
        end

        def branch(as, address)
          # as.jn(address)
          # as.je(address)
          raise "Don't use this node direct"
        end
          
        def collect_candidate_type(context)
          context = @cond.collect_candidate_type(context)
          context = @jmp_to_node.collect_candidate_type(context, self)
          @body.collect_candidate_type(context)
        end

        def compile(context)
          sig = context.to_signature
          context = super(context)
          context = @jmp_to_node.compile_block_value(context, self)
          jmptocs = @jmp_to_node.get_code_space(sig)

          curas = context.assembler
          context = @cond.compile(context)
          curas.with_retry do
            if context.ret_reg != TMPR then
              curas.mov(TMPR, context.ret_reg)
            end
            
            # In 64bit mode. It will be sign extended to 64 bit
            curas.and(TMPR, OpImmidiate32.new(~4))
          end

          curas.with_retry do
            branch(curas, jmptocs.var_base_address)
          end

          context = @body.compile(context)
          oldcs = context.set_code_space(jmptocs)
          context = @jmp_to_node.compile(context)
#          context.set_code_space(oldcs)

          context
        end
      end

      class BranchIfNode<BranchCommonNode
        def branch(as, address)
          as.jnz(address)
        end
      end

      class BranchUnlessNode<BranchCommonNode
        def branch(as, address)
          as.jz(address)
        end
      end

      class JumpNode<BaseNode
        include HaveChildlenMixin

        def initialize(parent, jmpto)
          super(parent)
          @jmp_to_node = jmpto
        end

        def traverse_childlen(&block)
          @jmp_to_node.traverse_block_value(self, &block)
          yield @jmp_to_node
        end

        def collect_candidate_type(context)
          block = lambda {|rec| 
            rec.collect_candidate_type(context)
          }
          tcontext = @jmp_to_node.traverse_block_value(self, &block)
          if tcontext then
            context = tcontext
          end
          @jmp_to_node.collect_candidate_type(context, self)
        end

        def compile(context)
          sig = context.to_signature
          context = super(context)
          context = @jmp_to_node.compile_block_value(context, self)
          jmptocs = @jmp_to_node.get_code_space(sig)

          curas = context.assembler
          curas.with_retry do
            curas.jmp(jmptocs.var_base_address)
            curas.ud2   # Maybe no means but this line may be useful
          end

          oldcs = context.set_code_space(jmptocs)
          context = @jmp_to_node.compile(context)
          context.set_code_space(oldcs)
          context
        end
      end

      # Holder of Nodes Assign. These assignes execute parallel potencially.
      class LetNode<BaseNode
        include HaveChildlenMixin
      end

      # Multiplexer of node (Using YARV stack operation)
      class MultiplexNode<BaseNode
        include HaveChildlenMixin
        include NodeUtil

        def initialize(node)
          super(node.parent)
          @node = node
          @compiled_by_signature = []
          @res_area = nil
        end

        def traverse_childlen
          yield @node
        end

        def collect_info(context)
          tnode = search_frame_info
          offset = tnode.static_alloca(8)
          @res_area = OpIndirect.new(BPR, offset)
          @node.collect_info(context)
        end

        def collect_candidate_type(context)
          sig = context.to_signature          
          same_type(self, @node, sig, sig, context)
          same_type(@node, self, sig, sig, context)
          @node.collect_candidate_type(context)
        end

        def compile(context)
          sig = context.to_signature
          if !@compiled_by_signature.include?(sig) then
            context = @node.compile(context)
            asm = context.assembler
            if context.ret_reg.is_a?(OpRegistor) then
              asm.with_retry do
                asm.mov(@res_area, context.ret_reg)
              end
            else
              asm.with_retry do
                asm.mov(TMPR, context.ret_reg)
                asm.mov(@res_area, TMPR)
              end
            end
            context.set_reg_content(@res_area, self)
            @compiled_by_signature.push sig

            context
          else
            asm = context.assembler
            asm.with_retry do
              asm.mov(RETR, @res_area)
            end
            context.set_reg_content(@res_area, self)
            context.ret_reg = RETR
            context.ret_node = self

            context
          end
        end
      end

      # Literal
      class LiteralNode<BaseNode
        include TypeListWithoutSignature

        def initialize(parent, val)
          super(parent)
          @value = val
          @type = RubyType::BaseType.from_object(val)
        end
        
        attr :value

        def collect_candidate_type(context)
          # ??? 
          if @type == nil then 
            @type = RubyType::BaseType.from_object(@value) 
          end

          sig = context.to_signature
          case @value
          when Array
            add_type(sig, @type)
            @value.each do |ele|
              etype = RubyType::BaseType.from_object(ele)
              @element_node_list[0][1].add_type(sig, etype)
            end

          when Range
            @type = @type.to_box
            add_type(sig, @type)
            if @type.args == nil then
              @type.args = []
              ele = @value.first
              fstnode = LiteralNode.new(self, ele)
              context = fstnode.collect_candidate_type(context)
              @type.args.push fstnode
              ele = @value.last
              sndnode = LiteralNode.new(self, ele)
              @type.args.push sndnode
              context = sndnode.collect_candidate_type(context)
              ele = @value.exclude_end?
              exclnode = LiteralNode.new(self, ele)
              @type.args.push exclnode
              context = exclnode.collect_candidate_type(context)
              add_element_node(sig, fstnode, [0], context)
            end
          else
            add_type(sig, @type)
          end

          context
        end

        def compile(context)
          context = super(context)

          decide_type_once(context.to_signature)
          case @value
          when Fixnum
            val = @value
            if @type.boxed then
              val = val.boxing
            end
            context.ret_node = self
            context.ret_reg = OpImmidiateMachineWord.new(val)

          when Float
            val = @value
            if @type.boxed then
              val = val.boxing
              context.ret_reg = OpImmidiateMachineWord.new(val)
            else
              offm4 = OpIndirect.new(SPR, -AsmType::DOUBLE.size)
              asm = context.assembler
              asm.with_retry do
                asm.mov64(offm4, val.unboxing)
                asm.movsd(XMM0, offm4)
              end
              context.ret_reg = XMM0
            end
            context.ret_node = self
            context.set_reg_content(context.ret_reg, self)

          else
            if @var_value == nil then
              add = lambda { @value.address }
              @var_value = OpVarImmidiateAddress.new(add)
            end

            context.ret_node = self
            context.ret_reg = @var_value
            context = @type.gen_copy(context)
            context.set_reg_content(context.ret_reg, self)
          end

          context
        end

        def get_constant_value
          [@value]
        end
      end

      class ClassValueNode<BaseNode
        include HaveChildlenMixin

        def initialize(parent, define)
          super(parent)
          @define = define
        end

        def traverse_childlen
          yield @define
          yield @body
        end
        
        attr_accessor :define

        def collect_candidate_type(context)
          dmylit = LiteralNode.new(self, nil)
          arg = [dmylit, dmylit, @define]
          sig = []
          cursig = context.to_signature
          arg.each do |ele|
            ele.decide_type_once(cursig)
            sig.push ele.type
          end
          type = RubyType::BaseType.from_ruby_class(@define.klassclass)
          sig[2] = type
          context = @define.collect_candidate_type(context, arg, sig)

          @body.collect_candidate_type(context)
        end

        def compile(context)
#          raise "Can't compile"
          context = super(context)
          context = @define.compile(context)
          @body.compile(context)
        end
      end

      class SpecialObjectNode<BaseNode
        def initialize(parent, kind)
          super(parent)
          @kind = kind
        end

        
        attr :kind

        def collect_candidate_type(context)
          context
        end

        def compile(context)
#          raise "Can't compile"
          context = super(context)
          context
        end
      end

      # yield(invokeblock)
      class YieldNode<BaseNode
        include NodeUtil
        include SendUtil

        def initialize(parent)
          super(parent)
          @name = "block yield"
          @frame_info = search_frame_info
        end

        attr :name
        attr :frame_info

        def collect_info(context)
          context.yield_node.last.push @parent
          context
        end

        def collect_candidate_type(context)
          context
        end

        def calling_convention(context)
          :ytl
        end

        def method_top_node(ctop, slf)
          nil
        end

        def compile(context)
          context = super(context)
          asm = context.assembler
          # You can crash when you use yield in block.
          # You can fix this bug for traversing PTMPR for method top.
          # But is is little troublesome. So it  is not supported.
          prevenv = @frame_info.offset_arg(0, BPR)
          # offset of self is common, so it no nessery traverse prev frame
          # for @frame_info.
          slfarg = @frame_info.offset_arg(2, PTMPR)
          asm.with_retry do
            asm.mov(PTMPR, prevenv)
            asm.mov(PTMPR, slfarg)
          end
          context.ret_reg2 = PTMPR
          
          context.ret_reg = @frame_info.offset_arg(1, BPR)
          context.ret_node = self
          context.set_reg_content(context.ret_reg, self)
          context
        end
      end

      class CApiCommonNode<BaseNode
        include NodeUtil
        include SendUtil

        def initialize(parent, name, atype, rtype = :VALUE)
          super(parent)
          @name = name
          @frame_info = search_frame_info
          @arg_type = atype
          @ret_type = rtype
        end

        attr :name
        attr :frame_info
        attr :arg_type
        attr :ret_type

        def collect_candidate_type(context)
          context
        end

        def method_top_node(ctop, slf)
          nil
        end

        def compile(context)
          context = super(context)
          addr = lambda { 
            address_of(@name) 
          }
          context.ret_reg = OpVarMemAddress.new(addr)
          context.ret_node = self
          context.set_reg_content(context.ret_reg, self)
          context
        end
      end

      # C API (fix arguments)
      class FixArgCApiNode<CApiCommonNode
        def calling_convention(context)
          :c_fixarg_raw
        end
      end

      # C API (variable arguments)
      class VarArgCApiNode<CApiCommonNode
        def calling_convention(context)
          :c_vararg_raw
        end
      end

      # Method name
      class MethodSelectNode<BaseNode
        def initialize(parent, val)
          super(parent)
          @name = val
          @calling_convention = :unkown
          @reciever = nil
          @send_node = nil
          @ruby_reciever = nil
        end

        def set_reciever(sendnode)
          @send_node = sendnode
          if sendnode.is_fcall or sendnode.is_vcall then
            @reciever = @parent.class_top
            if @reciever == @parent.search_top and 
                !@reciever.is_a?(TopTopNode) then
              @reciever.make_klassclass_node
              @reciever = @reciever.klassclass_node
            end
          else
            @reciever = sendnode.arguments[2]
          end
        end
        
        attr :name
        attr :calling_convention
        attr_accessor :reciever

        def collect_candidate_type(context)
          context
        end

        def method_top_node(ctop, slf)
          if slf then
            ctop.search_method_with_super(@name, slf.ruby_type_raw)[0]
          else
            ctop.search_method_with_super(@name)[0]
          end
        end

        def calling_convention(context)
          if @send_node.is_fcall or @send_node.is_vcall then
            mtop = @reciever.search_method_with_super(@name)[0]
            if mtop then
              @calling_convention = :ytl
            else
              # reciever = Object
              recobj = @reciever.klass_object
              if recobj.is_a?(ClassClassWrapper) then
                recobj = recobj.value
              end
              if recobj then
                addr = recobj.method_address_of(@name)
                if addr then
                  if variable_argument?(recobj.method(@name).parameters) then
                    @calling_convention = :c_vararg
                  else
                    @calling_convention = :c_fixarg
                  end
                else
                  raise "Unkown method - #{recobj}##{@name}"
                  @calling_convention = :c
                end
              else
                raise "foo"
              end
            end
          else
            rtype = @reciever.decide_type_once(context.to_signature)
            rklass = rtype.ruby_type_raw
            knode = ClassTopNode.get_class_top_node(rklass)
            if knode and knode.search_method_with_super(@name)[0] then
              @calling_convention = :ytl
              @ruby_reciever = rklass
            else
              slfval = @reciever.get_constant_value
              mth = nil
              if slfval then
                begin
                  mth = slfval[0].instance_method(@name)
                  @ruby_reciever = slfval[0]
                rescue NameError
                end
              end
              if slfval == nil or mth == nil then
                if rklass.is_a?(ClassClassWrapper) then
                  rklass = rklass.value
                end
                begin
                  mth = rklass.instance_method(@name)
                rescue NameError
                  p @parent.debug_info
                  p context.to_signature
                  p @name
#                  p @reciever.func.reciever.class
                  p @reciever.instance_eval {@type_list }
=begin
                  mc = @reciever.get_send_method_node(context.to_signature)[0]
                  iv = mc.end_nodes[0].parent.value_node
                  p iv.instance_eval {@name}
                  p iv.instance_eval {@type_list}
=end
                  raise
                end
                @ruby_reciever = rtype.ruby_type_raw
              end

              if variable_argument?(mth.parameters) then
                @calling_convention = :c_vararg
              else
                @calling_convention = :c_fixarg
              end
            end
          end

          @calling_convention
        end

        def compile(context)
          context = super(context)
          if @send_node.is_fcall or @send_node.is_vcall then
            slfop = @parent.frame_info.offset_arg(2, BPR)
            asm = context.assembler
            asm.with_retry do
              asm.mov(PTMPR, slfop)
            end
            context.ret_reg2 = PTMPR
            mtop = @reciever.search_method_with_super(@name)[0]
            if mtop then
              sig = @parent.signature(context)
              cs = mtop.find_cs_by_signature(sig)
              context.ret_reg = cs.var_base_address
            else
              recobj = @reciever.klass_object
              if recobj.is_a?(ClassClassWrapper) then
                recobj = recobj.value
              end
              if recobj then
                addr = lambda {
                  recobj.method_address_of(@name)
                }
                if addr.call then
                  context.ret_reg = OpVarMemAddress.new(addr)
                  context.code_space.refer_operands.push context.ret_reg 
                  context.ret_node = self
                else
                  raise "Unkown method - #{@name}"
                  context.ret_reg = OpImmidiateAddress.new(0)
                  context.ret_node = self
                end
              else
                raise "foo"
              end
            end
          else
            context = @reciever.compile(context)
            rtype = context.ret_node.decide_type_once(context.to_signature)
            if @calling_convention != :ytl then
              context = rtype.gen_boxing(context)
              rtype = rtype.to_box
            elsif !rtype.boxed then
              context = rtype.gen_unboxing(context)
            end
            recval = context.ret_reg
            rrtype = rtype.ruby_type_raw
            knode = ClassTopNode.get_class_top_node(rrtype)
            mtop = nil

            if rtype.is_a?(RubyType::DefaultType0) then
              # Can't type inference. Dynamic method search
              mnval = @name.address
              addr = lambda {
                address_of("rb_obj_class")
              }
              objclass = OpVarMemAddress.new(addr)
              addr = lambda {
                address_of("ytl_method_address_of_raw")
              }
              addrof = OpVarMemAddress.new(addr)

              context.start_using_reg(TMPR2)
              context.start_arg_reg
              
              asm = context.assembler
              asm.with_retry do
                asm.push(recval)
                asm.mov(FUNC_ARG[0], recval)
                asm.call_with_arg(objclass, 1)
                asm.mov(FUNC_ARG[0], RETR)
                asm.mov(FUNC_ARG[1], mnval)
              end
              context = gen_save_thepr(context)
              asm.with_retry do
                asm.call_with_arg(addrof, 2)
                asm.mov(TMPR2, RETR)
                asm.pop(PTMPR)
              end
              context.set_reg_content(FUNC_ARG_YTL[0].dst_opecode, nil)
              context.set_reg_content(FUNC_ARG_YTL[1].dst_opecode, self)
              context.ret_reg2 = PTMPR
              
              context.end_arg_reg
              
              context.ret_node = self
              context.set_reg_content(RETR, self)
              context.set_reg_content(TMPR2, self)
              context.set_reg_content(PTMPR, @reciever)
              context.ret_reg = TMPR2

            elsif knode and
                mtop = knode.search_method_with_super(@name)[0] then
              asm = context.assembler
              if !rtype.boxed and rtype.ruby_type == Float then
                if recval != XMM0 then
                  asm.with_retry do
                    asm.mov(XMM0, recval)
                  end
                end
                context.ret_reg2 = XMM0
              else
                asm.with_retry do
                  asm.mov(PTMPR, recval)
                end
                context.ret_reg2 = PTMPR
              end

              sig = @parent.signature(context)
              cs = mtop.find_cs_by_signature(sig)
              context.ret_reg = cs.var_base_address

            else
              # regident type 

              asm = context.assembler
              if !rtype.boxed and rtype.ruby_type == Float then
                if recval != XMM0 then
                  asm.with_retry do
                    asm.mov(XMM0, recval)
                  end
                end
                context.ret_reg2 = XMM0
              else
                asm.with_retry do
                  asm.mov(PTMPR, recval)
                end
                context.ret_reg2 = PTMPR
              end

              addr = lambda {
                rrec = @ruby_reciever
                if rrec.is_a?(ClassClassWrapper) then
                  rrec = rrec.value
                end
                if rrec.class == Module then
                  name = @name
                  rrec.send(:method_address_of, name)
                else
                  rrec.method_address_of(@name)
                end
              }
              if addr.call then
                context.ret_reg = OpVarMemAddress.new(addr)
                context.code_space.refer_operands.push context.ret_reg 
                context.ret_node = self
              else
                raise "Unkown method - #{@name}"
                context.ret_reg = OpImmidiateAddress.new(0)
                context.ret_node = self
              end
            end
          end
          context
        end
      end

      # Variable Common
      class VariableRefCommonNode<BaseNode
      end

      # Local Variable
      class LocalVarRefCommonNode<VariableRefCommonNode
        include LocalVarNodeCodeGen
        include NodeUtil

        def initialize(parent, offset, depth)
          super(parent)
          @offset = offset
          @depth = depth

          tnode = search_frame_info
          @frame_info = tnode
          depth.times do |i|
            tnode = tnode.previous_frame
          end
          @current_frame_info = tnode
        end

        attr :frame_info
        attr :current_frame_info
      end

      class LocalVarRefNode<LocalVarRefCommonNode
        def initialize(parent, offset, depth)
          super
          @var_type_info = nil
        end

        def collect_info(context)
          vti = nil
          if context.modified_local_var.last[-@depth - 1] then
            vti = context.modified_local_var.last[-@depth - 1][@offset]
          end

          if vti then
            @var_type_info = vti.map {|e| e.dup }
          else
            raise "maybe bug"
            roff = @current_frame_info.real_offset(@offset)
            @var_type_info = [@current_frame_info.frame_layout[roff]]
          end

          context
        end

        def collect_candidate_type(context)
          @var_type_info.each do |topnode, node|
            cursig = context.to_signature
            varsig = context.to_signature(topnode)
            same_type(self, node, cursig, varsig, context)
            same_type(node, self, varsig, cursig, context)
          end
          context
        end

        def compile(context)
          context = super(context)
          context = gen_pursue_parent_function(context, @depth)
          base = context.ret_reg
          offarg = @current_frame_info.offset_arg(@offset, base)

          asm = context.assembler
          @type = nil
          rtype = decide_type_once(context.to_signature)
          if !rtype.boxed and rtype.ruby_type == Float then
            asm.with_retry do
              asm.mov(XMM0, offarg)
            end
            context.ret_reg = XMM0
          else
            asm.with_retry do
              asm.mov(TMPR, offarg)
            end
            context.ret_reg = TMPR
          end

          if base == TMPR2 then
            context.end_using_reg(TMPR2)
          end

          context.ret_node = self
          context
        end
      end

      class SelfRefNode<LocalVarRefNode
        def initialize(parent)
          super(parent, 2, 0)
          @classtop = search_class_top
          @topnode = search_top
        end

        def compile_main(context)
          offarg = @current_frame_info.offset_arg(@offset, BPR)
          context.ret_node = self
          context.ret_reg = offarg
          context
        end

#=begin
        def collect_candidate_type(context)
          if @topnode.is_a?(ClassTopNode) then
            @type = RubyType::BaseType.from_ruby_class(@classtop.klass_object)
            add_type(context.to_signature, @type)
            context
          else
            super(context)
          end
        end
#=end

        def compile(context)
#          context = super(context)
          compile_main(context)
        end
      end

      class LocalAssignNode<LocalVarRefCommonNode
        include HaveChildlenMixin
        def initialize(parent, offset, depth, val)
          super(parent, offset, depth)
          val.parent = self
          @val = val
        end

        def traverse_childlen
          yield @val
          yield @body
        end

        def collect_info(context)
          context = @val.collect_info(context)
          top = @frame_info.parent

          nodepare = nil
          if @depth > 0 then 
            nodepare = top.orig_modified_local_var[-@depth]
          end
          if nodepare then
            nodepare = nodepare[@offset]
          end
          if nodepare then
            nodepare.push [top, self]
          else
            nodepare = [[top, self]]
          end
            
          context.modified_local_var.last[-@depth - 1][@offset] = nodepare

          @body.collect_info(context)
        end
          
        def collect_candidate_type(context)
          context = @val.collect_candidate_type(context)
          cursig = context.to_signature
          same_type(self, @val, cursig, cursig, context)
#          same_type(@val, self, cursig, cursig, context)
          @body.collect_candidate_type(context)
        end

        def compile(context)
          context = super(context)
          context = @val.compile(context)

          decide_type_once(context.to_signature)
          if @type.boxed then
            @val.decide_type_once(context.to_signature)
            rtype = @val.type
            context = rtype.gen_boxing(context)
          end

          valr = context.ret_reg
          valn = context.ret_node
          context = gen_pursue_parent_function(context, @depth)
          base = context.ret_reg
          offarg = @current_frame_info.offset_arg(@offset, base)

          asm = context.assembler
          if valr.is_a?(OpRegistor) or 
              (valr.is_a?(OpImmidiate) and !valr.is_a?(OpImmidiate64)) then
            asm.with_retry do
              asm.mov(offarg, valr)
            end

          else
            asm.with_retry do
              asm.mov(TMPR, valr)
              asm.mov(offarg, TMPR)
            end
          end

          tmpctx = context
          @depth.times { tmpctx = tmpctx.prev_context}
          tmpctx.set_reg_content(offarg, valn)

          context.ret_reg = nil
          if base == TMPR2 then
            context.end_using_reg(base)
          end

          @body.compile(context)
        end
      end

      # Instance Variable
      class InstanceVarRefCommonNode<VariableRefCommonNode
        include NodeUtil

        def initialize(parent, name, mnode)
          super(parent)
          @name = name
          @method_node = mnode
          mname = nil
          if @method_node then
            mname = @method_node.get_constant_value
          end
          @method_name = mname
          @class_top = search_class_top
        end
      end

      class InstanceVarRefNode<InstanceVarRefCommonNode
        def initialize(parent, name, mnode)
          super
          @var_type_info = nil
        end

        def collect_info(context)
          vti = context.modified_instance_var[@name]
          if vti == nil then
            vti = []
            context.modified_instance_var[@name] = vti
          end
          # Not dup so vti may update after.
          @var_type_info = vti 

          context
        end

        def collect_candidate_type(context)
          @var_type_info.each do |src|
            cursig = context.to_signature
            same_type(self, src, cursig, cursig, context)
          end
          
          context
        end

        def compile_main(context)
          context
        end

        def compile(context)
          context = super(context)
          compile_main(context)
        end
      end

      class InstanceVarAssignNode<InstanceVarRefCommonNode
        include HaveChildlenMixin
        def initialize(parent, name, mnode, val)
          super(parent, name, mnode)
          val.parent = self
          @val = val
        end

        def traverse_childlen
          yield @val
          yield @body
        end

        def collect_info(context)
          context = @val.collect_info(context)
          if context.modified_instance_var[@name] == nil then
            context.modified_instance_var[@name] = []
          end
          context.modified_instance_var[@name].push self
          @body.collect_info(context)
        end

        def collect_candidate_type(context)
          context = @val.collect_candidate_type(context)
          cursig = context.to_signature
          same_type(self, @val, cursig, cursig, context)
#          same_type(@val, self, cursig, cursig, context)
          if cursig[2].boxed then
            @val.set_escape_node_backward(true)
          end
          @body.collect_candidate_type(context)
        end

        def compile_main(context)
          context
        end

        def compile(context)
          context = super(context)
          compile_main(context)
        end
      end

      class ConstantRefNode<VariableRefCommonNode
        include NodeUtil
        include TypeListWithoutSignature
        
        def initialize(parent, klass, name)
          super(parent)
          @name = name
          rklass = nil
          case klass
          when LiteralNode, ConstantRefNode
            rklass = klass.get_constant_value[0]
            klass = ClassTopNode.get_class_top_node(rklass)

          when ClassTopNode
            rklass = klass.get_constant_value[0]
            
          else
            klass = search_class_top
          end

          @class_top = klass # .search_class_top
          @value_node = nil
          clsnode = nil
          if klass then
            @value_node, clsnode = klass.search_constant_with_super(@name)
          end
          if clsnode == nil and rklass then
            @value_node = LiteralNode.new(self, rklass.const_get(@name))
          end
        end

        attr :value_node

        def collect_candidate_type(context)
          if @value_node.is_a?(ClassTopNode) then
            add_type(context.to_signature, @value_node.type)
          else
            context = @value_node.collect_candidate_type(context)
            cursig = context.to_signature
            same_type(self, @value_node, cursig, cursig, context)
          end
          context
        end

        def compile(context)
          case @value_node
          when ClassTopNode
            obj = @value_node.klass_object
            objadd = lambda { obj.address }
            context.ret_reg  = OpVarImmidiateAddress.new(objadd)

          else
            context = @value_node.compile(context)
          end
          
          context.ret_node = self
          context 
        end

        def get_constant_value
          @value_node.get_constant_value
        end
      end

      class ConstantAssignNode<VariableRefCommonNode
        include NodeUtil
        include HaveChildlenMixin
        
        def initialize(parent, klass, name, value)
          super(parent)
          @name = name
          @class_top = klass # .search_class_top
          @value = value

          if klass.is_a?(ClassTopNode) then
            klass.constant_tab[@name] = @value
          else
            pp klass.class
            raise "Not Implemented yet for set constant for dynamic class"
          end
        end

        def traverse_childlen
          yield @body
        end

        def collect_candidate_type(context)
          @body.collect_candidate_type(context)
        end
        
        def type
          @value.type
        end

        def compile(context)
          @body.compile(context)
        end
      end

      # Reference Register
      class RefRegister
      end
    end
  end
end
