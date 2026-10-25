print('declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)')
for name, depth in [('deep', 20000), ('typed_deep', 20000), ('shallow', 1)]:
    print(f'define i1 @{name}(ptr addrspace(1) %a, '
          'ptr addrspace(1) "java-klass"="9" "java-klass-exact" %typed) {')
    print('entry:')
    print('  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %a)')
    for i in range(1, depth + 1):
        print(f'  %c{i} = xor i1 %c{i-1}, false')
    print(f'  br i1 %c{depth}, label %yes, label %no')
    print('yes:')
    receiver = '%typed' if name == 'typed_deep' else '%a'
    print('  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), '
          f'ptr addrspace(1) {receiver})')
    print('  ret i1 %r')
    print('no:')
    print('  ret i1 false')
    print('}')
print('!java-method-compilation = !{}')
