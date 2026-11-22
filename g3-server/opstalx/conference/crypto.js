const text = new TextEncoder()
export const bytes = value => text.encode(value)
export const encode = value => btoa(String.fromCharCode(...new Uint8Array(value)))
export const urlKey = value => encode(value).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
export const roomCode = value => value.replace(/\s/g, '')
export const newSecret = () => urlKey(crypto.getRandomValues(new Uint8Array(32)))

// A private invitation is handled only by the native clients. Never fetch it
// or send its fragment to the room, portal, or signaling services.
export function parsePrivateInvite(value) {
  const match = /^opstalx:join\/([0-9]{10})#([A-Za-z0-9_-]{43})$/.exec(value.trim())
  if (!match) throw new Error('Der geschützte Einladungslink ist ungültig.')
  return {code:match[1], secret:match[2]}
}
