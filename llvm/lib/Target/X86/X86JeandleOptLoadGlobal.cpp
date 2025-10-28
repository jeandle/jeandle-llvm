//===- X86JeandleOptLoadGlobal.cpp - optimization of load global ----------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file defines the pass that optimizes loads of specially-marked
// global variables. For any instruction of the form:
//     movq GV(%rip), %dst
// where GV has metadata "jeandle.oop.handle", replaces it with:
//     movabsq $GV, %dst
// Safe in Jeandle: JeandleVM rewrites such oop handles into real
// object references (oops) and continuously maintains them at
// runtime to guarantee correctness and garbage-collection safety.
//
//===----------------------------------------------------------------------===//

#include "X86.h"
#include "X86InstrInfo.h"
#include "X86MachineFunctionInfo.h"
#include "X86Subtarget.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Metadata.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "x86-jeandle-opt-load-global"

namespace {

class X86JeandleOptLoadGlobal : public MachineFunctionPass {
public:
  static char ID;
  X86JeandleOptLoadGlobal() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "X86 Jeandle Opt Load Global";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    if (MF.getFunction().isDeclaration())
      return false;

    const X86Subtarget &STI = MF.getSubtarget<X86Subtarget>();
    const X86InstrInfo *TII = STI.getInstrInfo();
    bool Changed = false;

    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(), E = MBB.end(); I != E;) {
        MachineInstr &MI = *I;
        ++I; // Iterate safely: increment before possibly erasing current instr.

        if (MI.getOpcode() != X86::MOV64rm)
          continue;

        const MachineOperand &DispOp = MI.getOperand(4);
        if (!DispOp.isGlobal())
          continue;

        // Only optimize globals marked with custom metadata.
        const GlobalVariable *GV = dyn_cast<GlobalVariable>(DispOp.getGlobal());
        if (!GV || !GV->getMetadata("jeandle.oop.handle"))
          continue;

        Register DstReg = MI.getOperand(0).getReg();
        BuildMI(MBB, MI, MI.getDebugLoc(), TII->get(X86::MOV64ri))
            .addReg(DstReg)
            .addGlobalAddress(GV, DispOp.getOffset(), DispOp.getTargetFlags());

        MI.eraseFromParent();
        Changed = true;
      }
    }
    return Changed;
  }
};

} // end anonymous namespace

char X86JeandleOptLoadGlobal::ID = 0;

FunctionPass *llvm::createX86JeandleOptLoadGlobalPass() {
  return new X86JeandleOptLoadGlobal();
}

INITIALIZE_PASS(X86JeandleOptLoadGlobal, DEBUG_TYPE,
                "Rewrite mov @oop(%rip), %reg -> movabs $@oop_addr, %reg",
                false, false)
