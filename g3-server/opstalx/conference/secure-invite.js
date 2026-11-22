import {bytes, urlKey} from './crypto.js'
import {verifyAsync} from './vendor/ed25519.js'

const rawPortalKey = 'cvnGD1Zy7A6KJ+MeiZWJb3bw+g9Y7MkCz0yj8fvI26A='
const identifier = /^[A-Za-z0-9_-]{6,40}$/
const rawKey = /^[A-Za-z0-9_-]{43}$/
const purposes = ['conference', 'vas']
const subtle = () => crypto.subtle
const decode = value => Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')
  + '='.repeat((4 - value.length % 4) % 4)), char => char.charCodeAt(0))

export async function createInviteKey() {
  try {
    const pair = await subtle().generateKey('X25519', false, ['deriveBits'])
    return {
      publicKey:urlKey(await subtle().exportKey('raw', pair.publicKey)),
      async shared(peer) {
        const key = await subtle().importKey('raw', peer, 'X25519', false, [])
        return new Uint8Array(await subtle().deriveBits({name:'X25519',public:key},pair.privateKey,256))
      },
      dispose() {},
    }
  } catch (error) {
    if (error.name !== 'NotSupportedError') throw error
    const {scalarMult} = await import('./vendor/tweetnacl.js')
    const key = crypto.getRandomValues(new Uint8Array(32))
    return {
      publicKey:urlKey(scalarMult.base(key)),
      shared:peer=>scalarMult(key,peer),
      dispose:()=>key.fill(0),
    }
  }
}

export async function verifyInviteKey(certificate, recipient, purpose, trust = rawPortalKey) {
  if (!identifier.test(recipient) || !purposes.includes(purpose) ||
      typeof certificate !== 'string' || !/^[A-Za-z0-9_-]{1,450}\.[A-Za-z0-9_-]{86}$/.test(certificate)) {
    throw new Error('Der Geräteschlüssel fehlt oder ist ungültig.')
  }
  const [body, signature] = certificate.split('.')
  if (!await verifyAsync(decode(signature), bytes(body), decode(trust))) {
    throw new Error('Der Geräteschlüssel konnte nicht bestätigt werden.')
  }
  const info = JSON.parse(new TextDecoder().decode(decode(body)))
  const now = Math.floor(Date.now()/1000)
  if (info.iss !== 'opslinx-invite-key' || info.aud !== 'opstalx-e2ee-invite-v1' ||
      info.sub !== recipient || info.purpose !== purpose || !rawKey.test(info.key) ||
      !Number.isSafeInteger(info.exp) || info.exp <= now || info.exp > now + 305) {
    throw new Error('Der Geräteschlüssel ist abgelaufen oder gehört zu einem anderen Gerät.')
  }
  return info.key
}

function transcript(recipient, purpose, code, publicKey, ephemeral) {
  if (!identifier.test(recipient) || !purposes.includes(purpose) || !/^\d{10}$/.test(code)) {
    throw new Error('Die geschützte Einladung ist ungültig.')
  }
  return bytes(JSON.stringify([recipient,purpose,code,publicKey,ephemeral]))
}

async function invitationKey(pair, peer, context) {
  if (!rawKey.test(peer)) throw new Error('Der Geräteschlüssel ist ungültig.')
  const shared = await pair.shared(decode(peer))
  try {
    if (shared.every(byte=>byte===0)) throw new Error('Der Geräteschlüssel ist ungültig.')
    const material = await subtle().importKey('raw', shared, 'HKDF', false, ['deriveKey'])
    return await subtle().deriveKey({name:'HKDF',hash:'SHA-256',salt:bytes('OpsTalX/invite/v1'),info:context},
      material, {name:'AES-GCM',length:256}, false, ['encrypt','decrypt'])
  } finally {
    shared.fill(0)
  }
}

export async function sealInvitation(secret, recipient, purpose, code, publicKey) {
  if (!rawKey.test(secret)) throw new Error('Der Sitzungsschlüssel fehlt.')
  const sender = await createInviteKey()
  const clear = decode(secret)
  try {
    const context = transcript(recipient,purpose,code,publicKey,sender.publicKey)
    const key = await invitationKey(sender,publicKey,context)
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const box = await subtle().encrypt({name:'AES-GCM',iv,additionalData:context},key,clear)
    return {pub:sender.publicKey,iv:urlKey(iv),box:urlKey(box),recipientKey:publicKey}
  } finally {
    clear.fill(0)
    sender.dispose()
  }
}

export async function openInvitation(sealed, recipient, purpose, code, pair) {
  if (!sealed || sealed.recipientKey !== pair.publicKey || !rawKey.test(sealed.pub) ||
      !/^[A-Za-z0-9_-]{16}$/.test(sealed.iv) || !/^[A-Za-z0-9_-]{64}$/.test(sealed.box)) {
    throw new Error('Die geschützte Einladung passt nicht zu diesem Gerät.')
  }
  const context = transcript(recipient,purpose,code,pair.publicKey,sealed.pub)
  const key = await invitationKey(pair,sealed.pub,context)
  const clear = new Uint8Array(await subtle().decrypt({name:'AES-GCM',iv:decode(sealed.iv),additionalData:context},
    key,decode(sealed.box)))
  try {
    if (clear.length !== 32) throw new Error('Der Sitzungsschlüssel ist ungültig.')
    return urlKey(clear)
  } finally {
    clear.fill(0)
  }
}

export async function annotationKey(secret, room) {
  if (!rawKey.test(secret) || !/^[a-f0-9]{32}$/.test(room)) throw new Error('Ungültiger Video-Hilfe-Schlüssel.')
  const clear = decode(secret)
  try {
    const material = await subtle().importKey('raw',clear,'HKDF',false,['deriveKey'])
    return await subtle().deriveKey({name:'HKDF',hash:'SHA-256',salt:bytes(room),info:bytes('OpsLinX/vas/annotations/v1')},
      material,{name:'AES-GCM',length:256},false,['encrypt','decrypt'])
  } finally {
    clear.fill(0)
  }
}

export async function sealAnnotation(key, binding, message) {
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const data = await subtle().encrypt({name:'AES-GCM',iv,additionalData:bytes(binding)},key,bytes(JSON.stringify(message)))
  return {v:1, iv:urlKey(iv), box:urlKey(data)}
}

export async function openAnnotation(key, binding, sealed) {
  if (sealed?.v !== 1 || !/^[A-Za-z0-9_-]{16}$/.test(sealed.iv) ||
      typeof sealed.box !== 'string' || sealed.box.length > 30000 || !/^[A-Za-z0-9_-]{22,}$/.test(sealed.box)) {
    throw new Error('Ungültiger verschlüsselter Hinweis.')
  }
  const clear = await subtle().decrypt({name:'AES-GCM',iv:decode(sealed.iv),additionalData:bytes(binding)},
    key,decode(sealed.box))
  return JSON.parse(new TextDecoder().decode(clear))
}
