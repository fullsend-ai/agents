import { render } from 'tinytemplate-demo';

// Renders a greeting from a template the caller supplies.
export function greeting(templateFromRequest, name) {
  return render(templateFromRequest, { name });
}
