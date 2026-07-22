const entries: string[] = [];

export function appendDiagnostic(category: string, message: string) {
  entries.push(`[${new Date().toISOString()}] [${category}] ${message}`);
  if (entries.length > 300) {
    entries.splice(0, entries.length - 300);
  }
}

export function diagnosticText() {
  return entries.join("\n");
}
