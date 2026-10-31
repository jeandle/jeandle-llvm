# Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
#
# Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

print('''@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
@oop_handle_Mirror_2 = external global ptr addrspace(1)
declare i32 @jeandle.class_is_primitive(ptr addrspace(1))
''')


def dag(name, depth, unknown=False, mixed=False):
    print(f'define i32 @{name}(i1 %c, ptr addrspace(1) %unknown) #0 gc "hotspotgc" {{')
    print('entry:')
    print('  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0')
    other = 2 if mixed else 1
    print(f'  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_{other}')
    arm = '%unknown' if unknown else '%b'
    print(f'  %m0 = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) {arm}')
    for i in range(1, depth):
        print(f'  %m{i} = select i1 %c, ptr addrspace(1) %m{i-1}, ptr addrspace(1) %m{i-1}')
    print(f'  %query = call i32 @jeandle.class_is_primitive(ptr addrspace(1) %m{depth-1})')
    print('  ret i32 %query\n}\n')


dag('shared_dag', 28)
dag('unknown_dag', 28, unknown=True)
dag('mixed_mirrors', 1, mixed=True)
dag('deep_dag', 40)

print('define i32 @wide_phi(i32 %index) #0 gc "hotspotgc" {\nentry:')
print('  switch i32 %index, label %p0 [')
for i in range(1, 300):
    print(f'    i32 {i}, label %p{i}')
print('  ]')
for i in range(300):
    print(f'p{i}:\n  %v{i} = load ptr addrspace(1), ptr @oop_handle_Mirror_{i % 2}\n  br label %merge')
print('merge:')
print('  %mirror = phi ptr addrspace(1) ' + ', '.join(f'[%v{i}, %p{i}]' for i in range(300)))
print('  %query = call i32 @jeandle.class_is_primitive(ptr addrspace(1) %mirror)\n  ret i32 %query\n}\n')

print('''define i32 @cyclic_mirrors(i1 %c) #0 gc "hotspotgc" {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  br label %loop
loop:
  %mirror = phi ptr addrspace(1) [%a, %entry], [%next, %loop]
  %next = select i1 %c, ptr addrspace(1) %mirror, ptr addrspace(1) %b
  br i1 %c, label %loop, label %exit
exit:
  %query = call i32 @jeandle.class_is_primitive(ptr addrspace(1) %mirror)
  ret i32 %query
}
attributes #0 = { "java-method"="1" }
!java-method-compilation = !{}
''')


def equality_dag(name, depth, swapped=False, unknown=False):
    print(f'define i1 @{name}(i1 %c, ptr addrspace(1) %unknown) #0 gc "hotspotgc" {{')
    print('entry:')
    for name_, id_ in [('a', 0), ('b', 1), ('other', 2)]:
        print(f'  %{name_} = load ptr addrspace(1), ptr @oop_handle_Mirror_{id_}')
    arm = '%unknown' if unknown else '%b'
    print(f'  %m0 = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) {arm}')
    for i in range(1, depth):
        print(f'  %m{i} = select i1 %c, ptr addrspace(1) %m{i-1}, ptr addrspace(1) %m{i-1}')
    left, right = f'%m{depth-1}', '%other'
    if swapped:
        left, right = right, left
    print(f'  %cmp = icmp eq ptr addrspace(1) {left}, {right}')
    print('  ret i1 %cmp\n}\n')


equality_dag('equality_shared_left', 28)
equality_dag('equality_shared_right', 28, swapped=True)
equality_dag('equality_unknown', 28, unknown=True)
equality_dag('equality_deep', 40)

print('''define i1 @equality_operand_pairs(i1 %c, i1 %d) #0 gc "hotspotgc" {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %left = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %right = select i1 %d, ptr addrspace(1) %a, ptr addrspace(1) %b
  %cmp = icmp eq ptr addrspace(1) %left, %right
  ret i1 %cmp
}

define i1 @equality_cycle(i1 %c) #0 gc "hotspotgc" {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %other = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  br label %loop
loop:
  %mirror = phi ptr addrspace(1) [%a, %entry], [%next, %loop]
  %next = select i1 %c, ptr addrspace(1) %mirror, ptr addrspace(1) %b
  br i1 %c, label %loop, label %exit
exit:
  %cmp = icmp eq ptr addrspace(1) %mirror, %other
  ret i1 %cmp
}
''')

print('define i1 @equality_wide(i32 %index) #0 gc "hotspotgc" {\nentry:')
print('  %other = load ptr addrspace(1), ptr @oop_handle_Mirror_2')
print('  switch i32 %index, label %p0 [')
for i in range(1, 100):
    print(f'    i32 {i}, label %p{i}')
print('  ]')
for i in range(100):
    print(f'p{i}:\n  %v{i} = load ptr addrspace(1), ptr @oop_handle_Mirror_{i % 2}\n  br label %merge')
print('merge:')
print('  %mirror = phi ptr addrspace(1) ' + ', '.join(f'[%v{i}, %p{i}]' for i in range(100)))
print('  %cmp = icmp eq ptr addrspace(1) %mirror, %other\n  ret i1 %cmp\n}\n')
