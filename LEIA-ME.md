# App Universal (white label)

Base de aplicativo white label, clonada do app da Celeiro Administradora (repositório `apoloweb/celeiro`, pasta `app/`, versão de 13/11/2026). Primeira marca aplicada: **Assembleia de Deus Ministério Madureira**.

## O que é

Um único arquivo, `index.html`, com as telas, o estilo e o comportamento. Abre em qualquer navegador, sem instalação e sem servidor. Para publicar na Vercel: projeto apontando para a raiz deste repositório, Framework "Other", sem comando de build.

- **É um protótipo, não o app das lojas.** Os dados ficam só na sessão e somem ao recarregar.
- **Logins são simulados.** Qualquer e-mail e senha entram.
- **Abaixo-assinados e textos dos serviços ainda são os de exemplo da Celeiro.**

## Como trocar de marca

| O que | Onde |
|---|---|
| Cores, fontes, raios | bloco `:root` no início do `<style>` do `index.html` |
| Nome e símbolo | objeto `const MARCA={` no `<script>` |
| Arquivos da logo | pasta `marcas/<cliente>/` (`logo.png` original, `simbolo.png` sem o nome, `logo-640.png`, `icone-192.png`) |
| Vídeos de exemplo | `videos:[` dentro de `const S={` |
| Lista de módulos | `const MODS=[` |
| Envio ao backoffice | `const Office={` |

## Marca atual: AD Ministério Madureira

- Cores tiradas da logo: índigo `#33327A` (institucional), amarelo `#FCBC19` (destaque), azul `#0272BD` (reserva).
- Fonte: Montserrat.
- Vídeos: mensagens do Bispo Samuel Ferreira (AD Brás, programa Palavra de Vida), tocadas pelo player do YouTube. As capas da lista não usam imagem.

## Pendências

1. **Envio de dados:** o app ainda envia instalações, cadastros e solicitações (veicular, energia, conta digital) ao Office da Celeiro, marcados como teste. Mantido por decisão do Paulo, até segunda ordem. A estrutura de servidor própria da igreja ainda não existe.
2. Imagens e vídeos da primeira tela interna: serão enviados pelo Paulo.
3. Texto institucional da igreja (tela "Quem somos").
4. Devocional e Bíblia online: ainda não construídos.
5. Conferir se cada vídeo do YouTube continua no ar e permite incorporação.
6. Autorização da igreja para uso da marca, das imagens e dos vídeos.
