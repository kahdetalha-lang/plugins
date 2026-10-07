# Atualização automática dos plugins: pacote para revisão

**Nada disto foi publicado.** Central, função do servidor e vitrine continuam como estão hoje.
Única exceção: a migração do banco (`codigo/migracao_auto_update.sql`), aplicada antes do pedido
de revisão. Ela só acrescenta colunas e configurações que nada lê hoje. O arquivo traz o comando
para desfazer.

## O que tem aqui

| Pasta | Conteúdo |
|---|---|
| `codigo/updater.rb` | Atualizador novo, arquivo inteiro (≈1.060 linhas, comentado em português) |
| `codigo/main.rb`, `codigo/ui.html` | Central com o atualizador ligado e a tela de Atualizações |
| `codigo/central-k-api.index.ts` | Função do servidor com a consulta leve `updates` |
| `codigo/admin-upload-package.index.ts`, `codigo/publicador_central_k.rb` | Controles: pausar, retomar e distribuir |
| `diferencas/` | Só o que mudou em relação ao que está em produção |
| `testes/` | Testes, simulação da Central e resultados |
| `tela_atualizacoes.png` | Como fica a aba Atualizações |

## Requisito por requisito

**1. Checagem leve e diária**
- A consulta `updates` devolve só versão, endereço, SHA-256, tamanho, compatibilidade e assinatura.
  Não baixa nada quando não há versão nova.
- Começa entre 30 s e 150 s depois da abertura do SketchUp (atraso sorteado, para espalhar as consultas).
- A data da última tentativa fica gravada antes da consulta. Uma trava de arquivo impede duas
  checagens ao mesmo tempo. O intervalo é de 24 h.
- Limites de tempo: 15 s para a consulta e 120 s para o download. Sem internet, o resultado fica
  "offline", nada aparece para o usuário e há nova tentativa no próximo período.

**2. Preparação sem interromper o trabalho**
- O download vai para a memória e a extração para `CentralK_updates/staging`, ao lado da pasta Plugins.
  A instalação em uso não é tocada.
- A rede usa a API assíncrona do SketchUp, e a extração dos pacotes, de 0,3 a 4 MB, é rápida.
- A troca acontece **ao fechar o SketchUp**. Para plugins que carregam depois da Central (REVEST),
  ela acontece **na abertura, antes de o plugin carregar**.

**3. Validação antes da troca**
- **Origem:** o servidor assina cada item com a mesma chave das licenças, e a Central confere com a
  chave pública que já tem. O endereço precisa ser HTTPS do nosso Supabase.
- **Integridade:** SHA-256, tamanho esperado e CRC de cada arquivo do zip.
- **Produto e versão:** o pacote só pode conter os nomes cadastrados para aquele produto, precisa
  ter carregador e assinatura da Trimble (`.susig`), e o carregador precisa conter a versão anunciada.
- **Compatibilidade:** versão mínima do SketchUp e sistema (Windows/Mac).
- **Recusa:** caminhos com `..`, caminhos absolutos, nomes estranhos, zip64, arquivos criptografados
  no zip, pacote grande demais ou com arquivos demais.
- **Nunca instala versão inferior ou igual.**

**4. Substituição completa e limitada ao produto**
- Cada produto tem uma lista de nomes exatos na raiz de Plugins:
  - cadastrada no servidor (`install_paths`);
  - registrada localmente a cada instalação;
  - descoberta pelo caminho real do plugin carregado, o que cobre instalações antigas com outro nome.
- A troca move a instalação antiga inteira e coloca a nova. Nenhum arquivo antigo sobra.
- Ficam fora da troca:
  - licenças e configurações, que estão em outra pasta;
  - outros plugins;
  - arquivos com nomes parecidos. Só nomes exatos são considerados, nunca semelhantes.

**5. Recuperação automática**
- A instalação anterior vai para um backup antes da troca. Se a troca falhar, ela volta na hora.
- Um diário (`journal.json`) é gravado depois de **cada movimento**. Se o SketchUp fechar ou a energia
  cair no meio, a abertura seguinte desfaz o que foi feito, e a troca é tentada de novo depois.
- O backup é apagado quando a abertura seguinte confirma que a versão nova carregou.
- Se a versão nova não carregar, a anterior é restaurada, e a versão problemática não é instalada de novo.
- **Prazo de retenção:** sem confirmação em 14 dias, o backup é apagado.

**6. Controle de publicação**
- `PublicadorCentralK.plugin(..., distribuir: 0)`: por padrão, a versão nova vai **só para o grupo
  piloto** (seus e-mails). Depois, `PublicadorCentralK.distribuir('klight', 30, token)` libera para
  30% e `distribuir('klight', 100, token)` para todos. A divisão é estável por computador.
- `PublicadorCentralK.pausar('klight', token)` suspende: o que estava só preparado é cancelado na
  próxima checagem. `retomar` libera de novo.
- Desligar geral: `auto_update_enabled = false` no `ck_config`.
- Uma versão que falhou num computador não é baixada nem instalada de novo ali.
- A Central continua se atualizando pelo mecanismo próprio, que já existe e é separado deste.

**7. Funcionamento e diagnóstico**
- **Licença e atualização são separadas:** falhar ao atualizar nunca bloqueia um plugin licenciado.
- **Registro local:** `updates/updater.log`, com no máximo cerca de 128 KB e rotação. E-mails e a
  pasta do usuário são mascarados.
- **Na Central:** versão instalada, última verificação com resultado e "Pronta: será concluída quando
  você fechar o SketchUp".
- **Mensagem só quando o usuário precisa agir:** depois de 3 trocas bloqueadas, aparece "Feche todas
  as janelas do SketchUp e abra de novo".

## Testes (todos passando)

**`testes/updater_test.rb`: 53 verificações**, com o sistema de arquivos real. Cada caso:

| Caso | Resultado esperado |
|---|---|
| Sem internet | Silencioso, tenta de novo depois |
| Download interrompido | Não marca falha, tenta de novo no período seguinte |
| Pacote inválido (assinatura, SHA-256, `../`, arquivo de outro produto, sem `.susig`, versão trocada, CRC corrompido) | Recusa e não baixa de novo |
| Falta de espaço em disco | Limpa o que preparou e não marca falha |
| Arquivo bloqueado (3 tentativas) | Desfaz cada tentativa e depois pede para reabrir o SketchUp |
| Instalação antiga com outro nome (`k_light.rb`) | Removida por completo |
| Duas janelas do SketchUp | A troca espera a última janela fechar |
| Queda de energia após cada movimento da troca | Restaura e depois conclui sem sobras |
| Versão nova que não carrega | Volta para a anterior e não reinstala |
| Versão inferior | Não instala |
| Distribuição gradual | Respeitada |
| Pausa e desligamento | Cancelam o preparo |
| SketchUp ou sistema incompatível | Ignorado |
| Plugin desinstalado pelo usuário | Não é reinstalado |
| Backup sem confirmação há 14 dias | Removido |
| Registro local | Sem dados pessoais |

Em todos os casos, presets, licença, outros plugins e arquivos de nome parecido continuam intactos.

**`testes/central_sim.rb`:** a Central inteira num SketchUp simulado, com os pacotes **reais** do
K.Light 1.0.4 (instalado) e 1.0.5 (atualização). O resultado final é idêntico ao pacote 1.0.5, sem
sobras.

## Limitações

- **Os testes foram feitos fora do SketchUp.** O comportamento real do Windows (arquivos travados
  pelo SketchUp, antivírus) precisa ser confirmado no grupo piloto antes de abrir para todos. É
  para isso que serve a distribuição gradual.
- **Quem ainda está na Central 1.0.2 continua vendo o botão "Atualizar" antigo** (instala por cima)
  até receber a 1.0.3 automaticamente.
- **Mac:** suportado no código, mas não testado.

## Se você aprovar, a ordem de publicação será

1. Publicar a função do servidor (a ação `updates` é nova; o resto fica idêntico).
2. Você assina a Central 1.0.3 na Trimble, eu publico a vitrine 1.0.4 (exige Central 1.0.3) e a Central.
3. Deixar `klight` em distribuição 0% (só o piloto), testar no seu computador e depois liberar.
