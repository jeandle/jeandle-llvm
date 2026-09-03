; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/budget-exceeded.cblog %s 2>&1 | FileCheck %s

; Per-query join budget: the guard sits below a single-predecessor chain deeper
; than the budget (128 joined blocks). The query must conservatively stay
; unknown (preserved) instead of folding — compile time stays bounded.
; (Bounded compile time in exchange for precision on chains this deep is the
; deliberate tradeoff pinned here.)

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj) gc "hotspotgc" {
entry:
  %ce = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %ce, label %b0, label %exit

b0:
  br label %b1

b1:
  br label %b2

b2:
  br label %b3

b3:
  br label %b4

b4:
  br label %b5

b5:
  br label %b6

b6:
  br label %b7

b7:
  br label %b8

b8:
  br label %b9

b9:
  br label %b10

b10:
  br label %b11

b11:
  br label %b12

b12:
  br label %b13

b13:
  br label %b14

b14:
  br label %b15

b15:
  br label %b16

b16:
  br label %b17

b17:
  br label %b18

b18:
  br label %b19

b19:
  br label %b20

b20:
  br label %b21

b21:
  br label %b22

b22:
  br label %b23

b23:
  br label %b24

b24:
  br label %b25

b25:
  br label %b26

b26:
  br label %b27

b27:
  br label %b28

b28:
  br label %b29

b29:
  br label %b30

b30:
  br label %b31

b31:
  br label %b32

b32:
  br label %b33

b33:
  br label %b34

b34:
  br label %b35

b35:
  br label %b36

b36:
  br label %b37

b37:
  br label %b38

b38:
  br label %b39

b39:
  br label %b40

b40:
  br label %b41

b41:
  br label %b42

b42:
  br label %b43

b43:
  br label %b44

b44:
  br label %b45

b45:
  br label %b46

b46:
  br label %b47

b47:
  br label %b48

b48:
  br label %b49

b49:
  br label %b50

b50:
  br label %b51

b51:
  br label %b52

b52:
  br label %b53

b53:
  br label %b54

b54:
  br label %b55

b55:
  br label %b56

b56:
  br label %b57

b57:
  br label %b58

b58:
  br label %b59

b59:
  br label %b60

b60:
  br label %b61

b61:
  br label %b62

b62:
  br label %b63

b63:
  br label %b64

b64:
  br label %b65

b65:
  br label %b66

b66:
  br label %b67

b67:
  br label %b68

b68:
  br label %b69

b69:
  br label %b70

b70:
  br label %b71

b71:
  br label %b72

b72:
  br label %b73

b73:
  br label %b74

b74:
  br label %b75

b75:
  br label %b76

b76:
  br label %b77

b77:
  br label %b78

b78:
  br label %b79

b79:
  br label %b80

b80:
  br label %b81

b81:
  br label %b82

b82:
  br label %b83

b83:
  br label %b84

b84:
  br label %b85

b85:
  br label %b86

b86:
  br label %b87

b87:
  br label %b88

b88:
  br label %b89

b89:
  br label %b90

b90:
  br label %b91

b91:
  br label %b92

b92:
  br label %b93

b93:
  br label %b94

b94:
  br label %b95

b95:
  br label %b96

b96:
  br label %b97

b97:
  br label %b98

b98:
  br label %b99

b99:
  br label %b100

b100:
  br label %b101

b101:
  br label %b102

b102:
  br label %b103

b103:
  br label %b104

b104:
  br label %b105

b105:
  br label %b106

b106:
  br label %b107

b107:
  br label %b108

b108:
  br label %b109

b109:
  br label %b110

b110:
  br label %b111

b111:
  br label %b112

b112:
  br label %b113

b113:
  br label %b114

b114:
  br label %b115

b115:
  br label %b116

b116:
  br label %b117

b117:
  br label %b118

b118:
  br label %b119

b119:
  br label %b120

b120:
  br label %b121

b121:
  br label %b122

b122:
  br label %b123

b123:
  br label %b124

b124:
  br label %b125

b125:
  br label %b126

b126:
  br label %b127

b127:
  br label %b128

b128:
  br label %b129

b129:
  br label %b130

b130:
  br label %b131

b131:
  br label %b132

b132:
  br label %b133

b133:
  br label %b134

b134:
  br label %b135

b135:
  br label %b136

b136:
  br label %b137

b137:
  br label %b138

b138:
  br label %b139

b139:
  br label %b140

b140:
  br label %b141

b141:
  br label %b142

b142:
  br label %b143

b143:
  br label %b144

b144:
  br label %b145

b145:
  br label %b146

b146:
  br label %b147

b147:
  br label %b148

b148:
  br label %b149

b149:
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  ret i1 %r

exit:
  ret i1 false
}

; The entry check stays, and the query at the chain bottom must stay too.
; CHECK: entry:
; CHECK-NEXT:   %ce = call i1 @jeandle.check_instanceof
; CHECK: b149:
; CHECK-NEXT:   %r = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   ret i1 %r

!java-method-compilation = !{}
