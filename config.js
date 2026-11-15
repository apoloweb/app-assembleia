/* Configuração do aplicativo (marca atual: AD Ministério Madureira).
   Use somente chaves PÚBLICAS (publishable ou anon). NUNCA coloque aqui uma chave secret / service_role. */
window.APP_CONFIG = {
  // Banco de dados do próprio aplicativo (Supabase): contas, vídeos, abaixo-assinados, solicitações e módulos
  url: "https://hhgvwuaijggpqrnjncbx.supabase.co",
  anonKey: "sb_publishable_QiQInXzmxdzFi6qj8H5JvQ_jHchHQXj",

  // Office da Celeiro: recebe cópia dos cadastros (leads) e das solicitações de serviço.
  // Para desligar esse envio, deixe officeUrl vazio ("").
  officeUrl: "https://wvvounloqtucagerizct.supabase.co",
  officeKey: "sb_publishable_ZSW04enHBahN-I8wfpkJfw_4z-HBuG3",
  teste: true   // true = o que chega ao Office fica marcado como teste, fora dos totais. Trocar para false no lançamento.
};
