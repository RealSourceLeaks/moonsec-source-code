using IronBrew2.Bytecode_Library.Bytecode;
using IronBrew2.Bytecode_Library.IR;

namespace IronBrew2.Obfuscator.Opcodes
{
	public class OpLoadK : VOpcode
	{
		public override bool IsInstruction(Instruction instruction) =>
			instruction.OpCode == Opcode.LoadConst; // && instruction.Chunk.Constants[instruction.B].Type != ConstantType.String;

		public override string GetObfuscated(ObfuscationContext context) =>
			"Stk[Inst[OP_A]]=Const[Inst[OP_B]];";

		public override void Mutate(Instruction instruction) =>
			instruction.B++;
	}
}