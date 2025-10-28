//===- AArch64JeandleOptLoadGlobal.cpp - optimization of load global ------===//
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
//     adrp  xDst, GV
//     ldr   xDst, [xDst, #:lo12:GV]
// where GV has metadata "jeandle.oop.handle", replaces it with:
//     movz  xDst, #:abs_g0:GV
//     movk  xDst, #:abs_g1:GV, lsl #16
//     movk  xDst, #:abs_g2:GV, lsl #32
// Safe in Jeandle: JeandleVM rewrites such oop handles into real
// object references (oops) and continuously maintains them at
// runtime to guarantee correctness and garbage-collection safety.
//
//===----------------------------------------------------------------------===//

#include "AArch64.h"
#include "AArch64InstrInfo.h"
#include "AArch64MachineFunctionInfo.h"
#include "AArch64Subtarget.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Metadata.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "aarch64-jeandle-opt-load-global"

namespace {

class AArch64JeandleOptLoadGlobal : public MachineFunctionPass {
public:
  static char ID;
  AArch64JeandleOptLoadGlobal() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "AArch64 Jeandle Opt Load Global";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    if (MF.getFunction().isDeclaration())
      return false;

    const AArch64Subtarget &STI = MF.getSubtarget<AArch64Subtarget>();
    const AArch64InstrInfo *TII = STI.getInstrInfo();
    bool Changed = false;

    for (MachineBasicBlock &MBB : MF) {
      for (auto I = MBB.begin(), E = MBB.end(); I != E;) {
        MachineInstr &AdrpMI = *I;
        ++I; // Iterate safely: increment before possibly erasing current instr.

        if (AdrpMI.getOpcode() != AArch64::ADRP)
          continue;

        const MachineOperand &AdrpDst = AdrpMI.getOperand(0);
        const MachineOperand &AdrpSym = AdrpMI.getOperand(1);
        if (!AdrpSym.isGlobal())
          continue;

        // Only optimize globals marked with custom metadata.
        const GlobalVariable *GV =
            dyn_cast<GlobalVariable>(AdrpSym.getGlobal());
        if (!GV || !GV->getMetadata("jeandle.oop.handle"))
          continue;

        // Check next MachineInstr
        if (I == E)
          continue;

        MachineInstr &LdrMI = *I;
        if (LdrMI.getOpcode() != AArch64::LDRXui)
          continue;

        const MachineOperand &LdrDst = LdrMI.getOperand(0);
        const MachineOperand &LdrBase = LdrMI.getOperand(1);
        const MachineOperand &LdrOffset = LdrMI.getOperand(2);

        if (LdrBase.getReg() != AdrpDst.getReg() || !LdrOffset.isGlobal() ||
            LdrOffset.getGlobal() != GV)
          continue;

        Register DstReg = LdrDst.getReg();
        DebugLoc DL = AdrpMI.getDebugLoc();

        // Load 48-bit absolute address of GV using:
        //   movz xDst, #:abs_g0:GV            // bits 0-15
        //   movk xDst, #:abs_g1:GV, lsl #16   // bits 16-31
        //   movk xDst, #:abs_g2:GV, lsl #32   // bits 32-47
        BuildMI(MBB, AdrpMI, DL, TII->get(AArch64::MOVZXi), DstReg)
            .addGlobalAddress(GV, 0, AArch64II::MO_G0 | AArch64II::MO_NC)
            .addImm(0);
        BuildMI(MBB, AdrpMI, DL, TII->get(AArch64::MOVKXi), DstReg)
            .addReg(DstReg)
            .addGlobalAddress(GV, 0, AArch64II::MO_G1 | AArch64II::MO_NC)
            .addImm(16);
        BuildMI(MBB, AdrpMI, DL, TII->get(AArch64::MOVKXi), DstReg)
            .addReg(DstReg)
            .addGlobalAddress(GV, 0, AArch64II::MO_G2 | AArch64II::MO_NC)
            .addImm(32);

        ++I;
        AdrpMI.eraseFromParent();
        LdrMI.eraseFromParent();
        Changed = true;
      }
    }
    return Changed;
  }
};

} // end anonymous namespace

char AArch64JeandleOptLoadGlobal::ID = 0;

FunctionPass *llvm::createAArch64JeandleOptLoadGlobalPass() {
  return new AArch64JeandleOptLoadGlobal();
}

INITIALIZE_PASS(AArch64JeandleOptLoadGlobal, DEBUG_TYPE,
                "Rewrite adrp+ldr @oop -> movz(G0)+movk(G1)+movk(G2)", false,
                false)
