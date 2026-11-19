// App Universal · função "assinatura-biometrica" (Supabase Edge Function)
//
// Confere a assinatura de abaixo-assinados feita com a biometria do aparelho (digital ou rosto),
// pelo padrão WebAuthn. A biometria nunca sai do aparelho: aqui chegam só uma chave pública,
// cadastrada uma vez por aparelho, e a cada assinatura uma confirmação criptográfica ligada ao
// texto assinado. Esta função confere a confirmação e só então manda gravar a assinatura.
//
// Só atende quem está logado no app. As regras de quem pode assinar ficam no banco
// (supabase.sql, seção 13); as operações bio_* só respondem a esta função.
//
// Publicar: Edge Functions > Deploy a new function > nome "assinatura-biometrica", colar este arquivo.
// Segredos opcionais (Edge Functions > Secrets):
//   APP_ORIGENS   endereços do app que podem usar a função, separados por vírgula.
//                 Padrão: https://assembleia.celeiroadministradora.com.br e o endereço anterior,
//                 https://universal.celeiroadministradora.com.br
//   APP_NOME      nome que o aparelho mostra ao pedir a biometria. Padrão: AD Ministério Madureira

import { withSupabase } from 'npm:@supabase/server@1'
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from 'npm:@simplewebauthn/server@13'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function segredo(nome) {
  return (Deno.env.get(nome) || '').trim()
}
function origensAceitas() {
  return (segredo('APP_ORIGENS') || 'https://assembleia.celeiroadministradora.com.br,https://universal.celeiroadministradora.com.br')
    .split(',').map((s) => s.trim().replace(/\/+$/, '')).filter(Boolean)
}

function paraB64url(bytes) {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
function deB64url(texto) {
  const t = String(texto || '').replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(t + '='.repeat((4 - (t.length % 4)) % 4))
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

const erro = (texto, extra) => ({ ok: false, erro: texto, ...(extra || {}) })

// Chama uma operação do banco. Devolve o resultado ou um objeto com "erro".
async function banco(c, nome, args) {
  const r = await c.rpc(nome, args)
  if (r.error) {
    console.error('Banco recusou', nome, r.error.message || r.error)
    return { erro: 'Não foi possível concluir agora. Tente de novo em instantes.' }
  }
  return r.data || { erro: 'Não foi possível concluir agora. Tente de novo em instantes.' }
}

// Regra da função, separada do servidor para poder ser testada.
// c = { userId, origem, ip, agente, rpc(nome, args) }
export async function tratar(corpo, c) {
  const acao = corpo && corpo.acao
  if (!c.userId) return erro('Entre na sua conta para assinar.')
  const origem = String(c.origem || '').replace(/\/+$/, '')
  if (!origensAceitas().includes(origem)) {
    return erro('Este endereço não está autorizado a usar a assinatura por biometria.')
  }
  const rpID = new URL(origem).hostname

  if (acao === 'registro-opcoes') {
    const desafio = crypto.getRandomValues(new Uint8Array(32))
    const r = await banco(c, 'bio_registro_iniciar', { p_user: c.userId, p_desafio: paraB64url(desafio) })
    if (r.erro) return erro(r.erro)
    const opcoes = await generateRegistrationOptions({
      rpName: segredo('APP_NOME') || 'AD Ministério Madureira',
      rpID,
      userName: r.email || 'conta',
      userDisplayName: r.nome || r.email || 'Conta',
      userID: new TextEncoder().encode(c.userId),
      challenge: desafio,
      attestationType: 'none',
      authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required', residentKey: 'preferred' },
    })
    return { ok: true, desafio_id: r.desafio_id, opcoes }
  }

  if (acao === 'registro-concluir') {
    if (!UUID.test(corpo.desafio_id || '') || !corpo.resposta) return erro('Pedido inválido')
    const d = await banco(c, 'bio_desafio_usar', { p_user: c.userId, p_desafio_id: corpo.desafio_id, p_tipo: 'registro' })
    if (d.erro) return erro(d.erro)
    let v
    try {
      v = await verifyRegistrationResponse({
        response: corpo.resposta,
        expectedChallenge: d.desafio,
        expectedOrigin: origem,
        expectedRPID: rpID,
        requireUserVerification: true,
      })
    } catch (e) {
      console.error('Cadastro de biometria recusado:', e && e.message)
      return erro('O aparelho não confirmou a biometria. Tente de novo.')
    }
    if (!v.verified || !v.registrationInfo) return erro('O aparelho não confirmou a biometria. Tente de novo.')
    const cred = v.registrationInfo.credential
    const transportes = cred.transports || (corpo.resposta.response && corpo.resposta.response.transports) || []
    const g = await banco(c, 'bio_registro_concluir', {
      p_user: c.userId, p_desafio_id: corpo.desafio_id, p_credencial: cred.id,
      p_chave: paraB64url(cred.publicKey), p_contador: cred.counter || 0,
      p_transportes: transportes, p_aparelho: c.agente || '',
    })
    if (g.erro) return erro(g.erro)
    return { ok: true, credencial_id: cred.id }
  }

  if (acao === 'assinar-opcoes') {
    if (!UUID.test(corpo.abaixo_id || '') || !corpo.credencial_id) return erro('Pedido inválido')
    const r = await banco(c, 'bio_assinatura_iniciar', {
      p_user: c.userId, p_abaixo: corpo.abaixo_id, p_cpf: String(corpo.cpf || ''), p_credencial: String(corpo.credencial_id),
    })
    if (r.erro) return erro(r.erro, r.sem_credencial ? { sem_credencial: true } : null)
    const opcoes = await generateAuthenticationOptions({
      rpID,
      challenge: deB64url(r.desafio),
      allowCredentials: [{ id: String(corpo.credencial_id), transports: r.transportes && r.transportes.length ? r.transportes : undefined }],
      userVerification: 'required',
    })
    if (opcoes.challenge !== r.desafio) return erro('Não foi possível concluir agora. Tente de novo em instantes.')
    return { ok: true, desafio_id: r.desafio_id, opcoes }
  }

  if (acao === 'assinar') {
    if (!UUID.test(corpo.desafio_id || '') || !corpo.resposta) return erro('Pedido inválido')
    const d = await banco(c, 'bio_desafio_usar', { p_user: c.userId, p_desafio_id: corpo.desafio_id, p_tipo: 'assinatura' })
    if (d.erro) return erro(d.erro)
    if (corpo.resposta.id !== d.credencial_id) return erro('A biometria usada não é a deste cadastro. Tente de novo.')
    let v
    try {
      v = await verifyAuthenticationResponse({
        response: corpo.resposta,
        expectedChallenge: d.desafio,
        expectedOrigin: origem,
        expectedRPID: rpID,
        credential: {
          id: d.credencial_id,
          publicKey: deB64url(d.chave_publica),
          counter: Number(d.contador || 0),
          transports: d.transportes && d.transportes.length ? d.transportes : undefined,
        },
        requireUserVerification: true,
      })
    } catch (e) {
      console.error('Assinatura por biometria recusada:', e && e.message)
      return erro('O aparelho não confirmou a biometria. Tente de novo.')
    }
    if (!v.verified) return erro('O aparelho não confirmou a biometria. Tente de novo.')
    const resp = corpo.resposta.response || {}
    const g = await banco(c, 'bio_assinatura_concluir', {
      p_user: c.userId, p_desafio_id: corpo.desafio_id,
      p_contador: (v.authenticationInfo && v.authenticationInfo.newCounter) || 0,
      p_ip: c.ip || '', p_aparelho: c.agente || '',
      p_prova: {
        padrao: 'WebAuthn',
        credencial: corpo.resposta.id,
        dados_autenticador: resp.authenticatorData,
        dados_cliente: resp.clientDataJSON,
        assinatura: resp.signature,
        origem,
        rp_id: rpID,
      },
    })
    if (g.erro) return erro(g.erro)
    return { ok: true, protocolo: g.protocolo, data: g.data, metodo: 'biometria' }
  }

  return erro('Pedido inválido')
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    let corpo
    try {
      corpo = await req.json()
    } catch (_) {
      return Response.json(erro('Pedido inválido'))
    }
    const r = await tratar(corpo, {
      userId: ctx.userClaims && ctx.userClaims.id ? ctx.userClaims.id : null,
      origem: req.headers.get('origin') || '',
      ip: req.headers.get('x-forwarded-for') || '',
      agente: req.headers.get('user-agent') || '',
      rpc: (nome, args) => ctx.supabaseAdmin.rpc(nome, args),
    })
    return Response.json(r)
  }),
}
