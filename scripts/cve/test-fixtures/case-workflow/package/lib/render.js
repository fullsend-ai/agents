export function render(template, data) {
  // Compiles template text as code.
  return new Function('data', 'return `' + template + '`')(data);
}
