test('integerBits', normal, compile_and_run, [''])
test('integerConversions', normal, compile_and_run, [''])
test('plusMinusInteger', [omit_ways(['ghci'])], compile_and_run, [''])
test('integerConstantFolding', normal, makefile_test, ['integerConstantFolding'])
test('fromToInteger', [], makefile_test, ['fromToInteger'])
test('IntegerConversionRules', [], makefile_test, ['IntegerConversionRules'])
test('gcdInteger', normal, compile_and_run, [''])

# skip ghci as it doesn't support unboxed tuples
test('integerImportExport', [omit_ways(['ghci'])], compile_and_run, [''])

# Disable GMP only tests
#test('integerGcdExt', [omit_ways(['ghci'])], compile_and_run, [''])
#test('integerPowMod', [], compile_and_run, [''])
#test('integerGmpInternals', [], compile_and_run, [''])
