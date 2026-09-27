# Como publicar mudanças na Central K

O comprador recebe tudo na **próxima vez que abrir a Central** — sem reinstalar.
Nada é consultado ao abrir o SketchUp, e nada é baixado se não houver versão nova.

## Preparar (uma vez)

1. Copie `publicador_central_k.rb` para o seu computador (ex.: `C:/CentralK/publicador_central_k.rb`).
2. Pegue o seu token de administradora: é o valor de `admin_upload_token` na tabela `ck_config`
   do projeto **Central K Pilot** no Supabase. Não compartilhe e não coloque dentro de nenhum `.rbz`.
3. No SketchUp: Janela › Console Ruby e rode:

   ```ruby
   load 'C:/CentralK/publicador_central_k.rb'
   ```

## Mudar a vitrine (textos, cards, imagens, categorias, layout)

1. Tenha uma pasta com a vitrine: `ui.html` na raiz e a pasta `media/` com as imagens
   (a mesma estrutura de dentro do plugin). Edite o que quiser.
   Nomes de arquivo: só letras, números, `-`, `_`, `.` e `/` (sem acentos).
2. Escolha um número de versão **diferente** do anterior (ex.: `1.0.2`, `1.0.3`…).
3. No Console Ruby:

   ```ruby
   PublicadorCentralK.vitrine('C:/CentralK/vitrine', '1.0.2', 'SEU_TOKEN')
   ```

4. Espere a linha `PRONTO`. Se aparecer `ERRO`, nada muda para os compradores.

Voltar atrás: publique de novo a vitrine antiga com um número novo.

## Atualizar o código da Central

1. Suba o número em `central_k_pilot.rb` (`VERSION`) e em `main.rb` (`CENTRAL_K_VERSION`).
2. Gere o `.rbz` e **assine na Trimble** (Extension Warehouse › Extension Signing).
3. No Console Ruby:

   ```ruby
   PublicadorCentralK.central('C:/CentralK/Central_K_1.0.2.rbz', '1.0.2', 'SEU_TOKEN')
   ```

A Central do comprador baixa, confere e instala sozinha ao abrir, e pede para reiniciar o SketchUp.
Se falhar (internet, etc.), não aparece erro para o comprador: tenta de novo na próxima abertura.

## Vitrine que depende de código novo

Se uma vitrine usa algo que só existe numa Central mais nova, informe a versão mínima:

```ruby
PublicadorCentralK.vitrine('C:/CentralK/vitrine', '2.0.0', 'SEU_TOKEN', min_central_version: '1.1.0')
```

Quem ainda estiver com uma Central mais antiga continua com a vitrine anterior até atualizar.
