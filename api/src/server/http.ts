export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message)
  }
}

export function text(value: unknown, name: string, limit = 256, empty = false): string {
  if (typeof value !== 'string' || value.length > limit || (!empty && !value.trim())) throw new ApiError(400, 'Invalid ' + name)
  return value.trim()
}

export function optionalText(value: unknown, name: string, limit = 256): string {
  return value === undefined || value === null ? '' : text(value, name, limit, true)
}

const securityHeaders = {
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
}

export function jsonResponse(data: unknown, status = 200) {
  const body = data === undefined || data === null ? '' : JSON.stringify(data)
  return new Response(body, { status, headers: { 'content-type': 'application/json; charset=utf-8', ...securityHeaders } })
}

export function textResponse(body: string, status = 200) {
  return new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8', ...securityHeaders } })
}

export async function readJson(request: Request): Promise<any> {
  const raw = await request.text()
  if (raw.length > 1_048_576) throw new ApiError(413, 'Request too large.')
  if (!raw) return {}
  try {
    return JSON.parse(raw)
  } catch {
    throw new ApiError(400, 'Invalid JSON request.')
  }
}

export function errorResponse(error: unknown) {
  if (error instanceof ApiError) return jsonResponse({ error: error.message }, error.status)
  console.error('Request failed', error)
  return jsonResponse({ error: 'Server error. Try again.' }, 500)
}
