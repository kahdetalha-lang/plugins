require 'fileutils'
require 'zlib'

module KahDetalha
  module KLight
    module Letreiro

      TEXTURE_CACHE_MAX_AGE = 30 * 24 * 60 * 60

      def self.backlight_texture_dir
        base = if Sketchup.platform == :platform_win
          ENV['LOCALAPPDATA'].to_s.empty? ? ENV['APPDATA'].to_s : ENV['LOCALAPPDATA'].to_s
        else
          File.join(Dir.home, 'Library', 'Application Support')
        end
        raise 'Não foi possível localizar a pasta de cache do K.Light.' if base.to_s.empty?
        File.join(base, 'KahDetalha', 'KLight', 'backlight')
      end

      def self.cleanup_backlight_textures(folder)
        cutoff = Time.now - TEXTURE_CACHE_MAX_AGE
        Dir.glob(File.join(folder, 'halo_*.png')).each do |path|
          FileUtils.rm_f(path) if File.mtime(path) < cutoff
        rescue StandardError
          # Um arquivo em uso não deve impedir a criação de um novo halo.
          nil
        end
      end

      # -----------------------------------------------------------------------
      # BACKLIGHT NATIVO — máscara única de todas as faces + campo de distância
      # compacto. Não há PNG, textura, preview pesado ou geometria por aresta.
      # A resolução é fixa e baixa de propósito: a geração fica imediata e o
      # suavizado do próprio SketchUp remove a leitura da malha.
      # -----------------------------------------------------------------------
      # v1 tentou uma grade SEPARADA por letra pra dar controle de "estilo"
      # difuso/separado — travava demais em textos com várias letras (cada
      # letra reconstruía a máscara + campo de distância + mesclagem do
      # zero). Também ficou difícil de perceber diferença do "separado" pro
      # "difuso" com largura baixa, já que os dois eram a mesma matemática.
      # Voltou pra UMA malha só (rápida, sempre), com "Largura" e "Queda"
      # como sliders diretos — reduzir a largura já separa letras próximas
      # sozinho, sem precisar de um modo à parte.
      def self.build_backlight_geo(ge, faces, params, model)
        faces = faces.uniq.select(&:valid?)
        raise 'Selecione as faces frontais do letreiro.' if faces.empty?

        normal = faces.first.normal.normalize
        origin = faces.first.vertices.first.position
        unless faces.all? { |f| f.normal.dot(normal).abs > 0.999 && ((f.vertices.first.position - origin).dot(normal)).abs < 0.001 }
          raise 'As faces do letreiro precisam estar no mesmo plano.'
        end

        axis = normal.parallel?(Geom::Vector3d.new(0,0,1)) ? Geom::Vector3d.new(1,0,0) : Geom::Vector3d.new(0,0,1)
        u = axis.cross(normal).normalize
        v = normal.cross(u).normalize
        points = faces.flat_map { |f| f.vertices.map(&:position) }
        uv = points.map { |pt| d = pt - origin; [d.dot(u), d.dot(v)] }
        min_u, max_u = uv.map(&:first).minmax
        min_v, max_v = uv.map(&:last).minmax
        span = [max_u - min_u, max_v - min_v].max
        raise 'O letreiro é pequeno demais para criar o halo.' if span < 0.01

        # Alcance e queda direto dos sliders "Largura do Halo" e "Queda do
        # degradê" (igual a fita de LED) — em vez de auto-calculado.
        radius    = (params[:halo_radius_cm].to_f.clamp(0.5, 25.0)) / 2.54
        falloff_k = params[:halo_falloff].to_f.clamp(1.0, 16.0)

        min_u -= radius; max_u += radius; min_v -= radius; max_v += radius

        # Resolução adaptativa: quer pelo menos ~14 pixels cobrindo o raio
        # do halo (senão um raio pequeno num letreiro grande fica chapado
        # em blocos — o "pixelado" que aconteceu antes). Piso 200 mantém a
        # nitidez de sempre pros casos normais; teto 380 evita a grade
        # explodir de tamanho em textos longos com halo bem fino.
          max_pixels = params[:halo_pixels].to_i
          max_pixels = 480 if max_pixels <= 0
          min_pixels = params[:preview_quality] ? 96 : 320

          # Logos/formas desenhadas à mão (curva orgânica) podem ter milhares
          # de vértices numa única face — mesmo com o corte por bbox acima,
          # classify_point ainda custa proporcional a isso EM CADA pixel da
          # face que contém aquele vértice. Sem reduzir a grade nesses casos,
          # o cálculo (cols × rows × custo do classify_point) podia travar o
          # SketchUp por minutos numa forma bem detalhada. Reduzimos o teto
          # (E o piso, senão o clamp abaixo quebra com min > max) de resolução
          # proporcionalmente ao total de vértices, mantendo a nitidez normal
          # de sempre pra geometria simples (a grande maioria dos letreiros).
          total_vertices = faces.sum { |f| f.vertices.size }
          if total_vertices > 1500
            budget = (480_000.0 / total_vertices).round.clamp(64, max_pixels)
            max_pixels = budget
            min_pixels = [min_pixels, budget].min
          end

          longest = ((span / radius) * 18.0).ceil.clamp(min_pixels, max_pixels)
        pixel = [max_u-min_u, max_v-min_v].max / longest.to_f
        cols = [((max_u-min_u)/pixel).ceil, 8].max
        rows = [((max_v-min_v)/pixel).ceil, 8].max
        mask = Array.new(cols * rows, false)

        # Bounding box (em u/v) de cada face, calculado uma única vez. Um
        # letreiro com várias letras/formas complexas (curvas orgânicas tipo
        # a de uma logo desenhada à mão) tem MUITOS vértices por face — sem
        # esse corte, cada um dos até 480×480 pixels da grade chamava
        # classify_point (nativo, mas ainda proporcional ao nº de vértices)
        # em TODAS as faces, mesmo nas que estão longe demais pra sequer
        # tocar aquele pixel. Isso é o que travava o SketchUp em logos
        # complexas — o corte por bbox elimina a maioria dessas chamadas
        # sem mudar o resultado (só pula faces que não têm como conter o
        # ponto).
        face_bounds = faces.map do |f|
          fuv = f.vertices.map { |vx| d = vx.position - origin; [d.dot(u), d.dot(v)] }
          fu = fuv.map(&:first); fv = fuv.map(&:last)
          [f, fu.min, fu.max, fv.min, fv.max]
        end

        # Rasterização por face: antes, CADA pixel percorria a lista inteira
        # de faces para descobrir quais bboxes poderiam contê-lo. O resultado
        # era O(cols × rows × letras), mesmo quando cada letra ocupava só uma
        # pequena parte da grade. Agora cada face visita diretamente apenas o
        # retângulo de pixels coberto por sua bbox. A classificação e os
        # centros amostrados são exatamente os mesmos; muda somente a ordem do
        # trabalho, portanto o halo final permanece idêntico.
        row_origins = Array.new(rows) do |y|
          py = min_v + (y + 0.5) * pixel
          origin.offset(v, py)
        end
        x_coords = Array.new(cols) { |x| min_u + (x + 0.5) * pixel }

        face_bounds.each do |face, fmin_u, fmax_u, fmin_v, fmax_v|
          x0 = (((fmin_u - min_u) / pixel) - 0.5).ceil.clamp(0, cols - 1)
          x1 = (((fmax_u - min_u) / pixel) - 0.5).floor.clamp(0, cols - 1)
          y0 = (((fmin_v - min_v) / pixel) - 0.5).ceil.clamp(0, rows - 1)
          y1 = (((fmax_v - min_v) / pixel) - 0.5).floor.clamp(0, rows - 1)
          next if x1 < x0 || y1 < y0

          (y0..y1).each do |y|
            row_index = y * cols
            row_origin = row_origins[y]
            (x0..x1).each do |x|
              index = row_index + x
              next if mask[index] # Já preenchido por outra face sobreposta.

              pt = row_origin.offset(u, x_coords[x])
              # PointNotOnPlane não representa área preenchida. Comparar apenas
              # com PointOutside fazia pequenas imprecisões do plano virarem
              # grandes regiões sólidas, gerando faixas e contornos falsos.
              classification = face.classify_point(pt)
              mask[index] = classification == Sketchup::Face::PointInside ||
                            classification == Sketchup::Face::PointOnEdge ||
                            classification == Sketchup::Face::PointOnVertex
            end
          end
        end

        # Campo de distância EUCLIDIANA EXATA (Felzenszwalt & Huttenlocher,
        # 2 passadas 1D — por coluna, depois por linha), no lugar do chamfer
        # de 2 passadas anterior (pesos 1/√2). O chamfer tem um viés
        # direcional conhecido: o erro varia com o ângulo (pior perto de
        # certas diagonais). Numa ponta pontiaguda, esse viés se repete em
        # cada uma das `bands` camadas de opacidade empilhadas do halo e a
        # soma delas aparecia como um raio fino na direção onde o erro é
        # maior — era o "espinho" reportado. EDT exato não tem viés de
        # direção nenhum (as curvas de distância são círculos perfeitos),
        # eliminando essa classe de artefato de vez.
        edt_1d = lambda do |f|
          n = f.size
          d    = Array.new(n)
          # Renomeado pra "apex" (era "v") — dentro desta lambda, "v" tinha o
          # mesmo nome do vetor de base do plano (v = normal.cross(u)) já
          # definido fora. Como a lambda é uma closure, atribuir a "v" aqui
          # sobrescrevia esse vetor externo em vez de criar uma variável nova
          # — quebrava todo .offset(v, ...) chamado depois desta função (daí
          # o erro "wrong number of values in array": o código tentava usar
          # este array como se fosse um Vector3d).
          apex = Array.new(n, 0)
          z    = Array.new(n + 1)
          k    = 0
          apex[0] = 0
          z[0] = -1.0e18
          z[1] = 1.0e18
          (1...n).each do |q|
            loop do
              s = ((f[q] + q * q) - (f[apex[k]] + apex[k] * apex[k])) / (2.0 * q - 2.0 * apex[k])
              if s <= z[k]
                k -= 1
                next
              end
              k += 1
              apex[k] = q
              z[k] = s
              z[k + 1] = 1.0e18
              break
            end
          end
          k = 0
          (0...n).each do |q|
            k += 1 while z[k + 1] < q
            d[q] = (q - apex[k])**2 + f[apex[k]]
          end
          d
        end

        inf = 1.0e18
        sq  = mask.map { |solid| solid ? 0.0 : inf }

        # 1ª passada: cada coluna, ao longo de y.
        cols.times do |x|
          col = Array.new(rows) { |y| sq[y * cols + x] }
          col = edt_1d.call(col)
          rows.times { |y| sq[y * cols + x] = col[y] }
        end
        # 2ª passada: cada linha, ao longo de x, usando o resultado da 1ª
        # passada como base — o resultado final é a distância euclidiana 2D
        # exata (ao quadrado) até o pixel "sólido" mais próximo.
        rows.times do |y|
          row = (0...cols).map { |x| sq[y * cols + x] }
          row = edt_1d.call(row)
          cols.times { |x| sq[y * cols + x] = row[x] }
        end

        dist = sq.map { |v2| Math.sqrt(v2) }

        rgb = params[:rgb_custom].is_a?(Array) ? params[:rgb_custom].map { |n| n.to_i.clamp(0,255) } : PRESETS.fetch(params[:preset].to_s, PRESETS['quente'])
        intensity = params[:alpha_max].to_f.clamp(0.05, 1.0)
          bands = params[:halo_bands].to_i
          if bands <= 0
            # O nº de faces geradas (e o custo de add_face, que é o que
            # trava em formas complexas) escala com bands × nº de "ilhas"
            # (letras/formas separadas) do contorno — cada ilha multiplica
            # os blocos do degradê pro mesmo nº de bandas. Baixamos a base
            # de 28 pra 16 (já reduz ~43% das faces sem ficar visivelmente
            # menos suave) e reduzimos mais ainda quando há várias ilhas
            # (ex.: uma logo + várias letras selecionadas de uma vez).
            bands = faces.size > 3 ? [16 - (faces.size - 3), 8].max : 16
          end
          bands = bands.clamp(6, 28)
        mats = Array.new(bands) do |i|
          material = model.materials.add(Core.next_mat_name("KB_#{i}"))
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = ((i + 1).to_f / bands * intensity).clamp(0.02, 1.0)
          material
        end
        band_map = Array.new(cols * rows)
        rows.times do |y|
          cols.times do |x|
            i = y * cols + x
            next if mask[i]
            t = dist[i] * pixel / radius
            next if t >= 1.0
            alpha = intensity * Math.exp(-falloff_k * t * t)
            band_map[i] = [(alpha * bands).floor, bands - 1].min if alpha >= 0.025
          end
        end
        # Mesclagem gulosa: blocos contíguos da mesma banda viram uma face só.
        # Menos faces = menos artefatos de transparência e viewport mais leve.
        #
        # NOTA: uma tentativa anterior aqui trocou o add_face por bloquinho
        # por criação em lote via PolygonMesh/fill_from_mesh (mais rápida em
        # teoria). Na prática o resultado final saiu quase sem opacidade —
        # provavelmente algum detalhe de material/winding do fill_from_mesh
        # não se comporta igual ao add_face nessa versão do SketchUp, e sem
        # conseguir testar ao vivo não dá pra arriscar de novo. Voltou pro
        # add_face (comprovadamente correto); a lentidão em formas complexas
        # é resolvida reduzindo `bands` (ver abaixo), não trocando o método
        # de criação de face.
        used = Array.new(cols * rows, false)
        count = 0
        rows.times do |y|
          cols.times do |x|
            i = y * cols + x; band = band_map[i]
            next if band.nil? || used[i]
            width = 0
            while x + width < cols && band_map[y * cols + x + width] == band && !used[y * cols + x + width]
              width += 1
            end
            height = 1
            while y + height < rows && (0...width).all? { |dx| band_map[(y + height) * cols + x + dx] == band && !used[(y + height) * cols + x + dx] }
              height += 1
            end
            height.times { |dy| width.times { |dx| used[(y + dy) * cols + x + dx] = true } }
            depth = 0.8.mm + (bands - band) * 0.001.mm
            p00 = origin.offset(u, min_u + x * pixel).offset(v, min_v + y * pixel).offset(normal.reverse, depth)
            p10 = origin.offset(u, min_u + (x + width) * pixel).offset(v, min_v + y * pixel).offset(normal.reverse, depth)
            p11 = origin.offset(u, min_u + (x + width) * pixel).offset(v, min_v + (y + height) * pixel).offset(normal.reverse, depth)
            p01 = origin.offset(u, min_u + x * pixel).offset(v, min_v + (y + height) * pixel).offset(normal.reverse, depth)
            face = ge.add_face(p00, p10, p11, p01) rescue nil
            next unless face
            face.material = mats[band]; face.back_material = mats[band]
            face.set_attribute(ATTR_DICT, 'backlight_band', band)
            count += 1
          end
        end
        ge.grep(Sketchup::Edge).each { |e| e.hidden = true; e.soft = true; e.smooth = true if e.valid? }
        { created: count, materials: mats }
      end

      # BACKLIGHT DIFUSO — gera uma única textura RGBA branca (alpha = halo)
      # e a aplica em uma única face. A cor vem do material colorizado, então
      # preview/edição de cor e intensidade não recriam nem a malha nem a PNG.
      def self.build_backlight_texture_geo(ge, faces, params, model)
        faces = faces.uniq.select(&:valid?)
        raise 'Selecione as faces frontais do letreiro.' if faces.empty?
        normal = faces.first.normal.normalize
        origin = faces.first.vertices.first.position
        unless faces.all? { |f| f.normal.dot(normal).abs > 0.999 && ((f.vertices.first.position - origin).dot(normal)).abs < 0.001 }
          raise 'As faces precisam estar no mesmo plano.'
        end
        axis = normal.parallel?(Geom::Vector3d.new(0,0,1)) ? Geom::Vector3d.new(1,0,0) : Geom::Vector3d.new(0,0,1)
        u = axis.cross(normal).normalize
        v = normal.cross(u).normalize
        uv = faces.flat_map { |f| f.vertices.map(&:position) }.map { |pt| d = pt - origin; [d.dot(u), d.dot(v)] }
        min_u, max_u = uv.map(&:first).minmax; min_v, max_v = uv.map(&:last).minmax
        span = [max_u-min_u, max_v-min_v].max
        raise 'O elemento é pequeno demais para criar o halo.' if span < 0.01
        radius = (params[:halo_radius_cm].to_f.clamp(0.5, 25.0)) / 2.54
        falloff_k = params[:halo_falloff].to_f.clamp(1.0, 16.0)
        min_u -= radius; max_u += radius; min_v -= radius; max_v += radius
        requested_pixels = params[:halo_pixels].to_i
        longest = if requested_pixels > 0
          requested_pixels
        elsif params[:preview_quality]
          320
        else
          640
        end
        longest = longest.clamp(256, 640)
        pixel = [max_u-min_u, max_v-min_v].max / longest.to_f
        cols = [((max_u-min_u)/pixel).ceil, 16].max
        rows = [((max_v-min_v)/pixel).ceil, 16].max
        mask = Array.new(cols * rows, false)
        rows.times do |y|
          py = min_v + (y + 0.5) * pixel
          cols.times do |x|
            px = min_u + (x + 0.5) * pixel
            point = origin.offset(u, px).offset(v, py)
            mask[y*cols+x] = faces.any? { |face| face.classify_point(point) != Sketchup::Face::PointOutside }
          end
        end
        inf = 1.0e9
        dist = mask.map { |solid| solid ? 0.0 : inf }
        rows.times do |y|
          cols.times do |x|
            i = y*cols+x; next if dist[i] == 0.0
            best = dist[i]
            best = [best, dist[i-1]+1.0].min if x > 0
            best = [best, dist[i-cols]+1.0].min if y > 0
            best = [best, dist[i-cols-1]+1.4142].min if x > 0 && y > 0
            best = [best, dist[i-cols+1]+1.4142].min if x+1 < cols && y > 0
            dist[i] = best
          end
        end
        (rows-1).downto(0) do |y|
          (cols-1).downto(0) do |x|
            i = y*cols+x; best = dist[i]
            best = [best, dist[i+1]+1.0].min if x+1 < cols
            best = [best, dist[i+cols]+1.0].min if y+1 < rows
            best = [best, dist[i+cols+1]+1.4142].min if x+1 < cols && y+1 < rows
            best = [best, dist[i+cols-1]+1.4142].min if x > 0 && y+1 < rows
            dist[i] = best
          end
        end
        raw = String.new(encoding: Encoding::BINARY)
        rows.times do |y|
          raw << "\x00" # filtro PNG
          cols.times do |x|
            i = y*cols+x
            alpha = if mask[i]
              0
            else
              t = dist[i] * pixel / radius
              t >= 1.0 ? 0 : (255.0 * Math.exp(-falloff_k*t*t)).round
            end
            raw << 255.chr << 255.chr << 255.chr << alpha.chr
          end
        end
        # Cache gravável fora da pasta de instalação. Em Windows a pasta do
        # plugin pode ficar em Program Files e bloquear File.binwrite.
        folder = backlight_texture_dir
        FileUtils.mkdir_p(folder)
        cleanup_backlight_textures(folder)
        path = File.join(folder, "halo_#{Time.now.to_i}_#{rand(1_000_000)}.png")
        png_chunk = lambda { |tag, data| [data.bytesize].pack('N') + tag + data + [Zlib.crc32(tag + data)].pack('N') }
        data = "\x89PNG\r\n\x1a\n".b + png_chunk.call('IHDR', [cols, rows, 8, 6, 0, 0, 0].pack('NNC5')) + png_chunk.call('IDAT', Zlib::Deflate.deflate(raw, Zlib::BEST_SPEED)) + png_chunk.call('IEND', ''.b)
        File.binwrite(path, data)
        p00 = origin.offset(u,min_u).offset(v,min_v).offset(normal.reverse,1.mm)
        p10 = origin.offset(u,max_u).offset(v,min_v).offset(normal.reverse,1.mm)
        p01 = origin.offset(u,min_u).offset(v,max_v).offset(normal.reverse,1.mm)
        p11 = origin.offset(u,max_u).offset(v,max_v).offset(normal.reverse,1.mm)
        face = ge.add_face(p00,p10,p11,p01)
        material = model.materials.add(Core.next_mat_name('KB_TX'))
        material.texture = path
        rgb = params[:rgb_custom].is_a?(Array) ? params[:rgb_custom].map { |n| n.to_i.clamp(0,255) } : PRESETS.fetch(params[:preset].to_s, PRESETS['quente'])
        material.color = Sketchup::Color.new(*rgb)
        material.colorize_type = Sketchup::Material::COLORIZE_TINT if material.respond_to?(:colorize_type=)
        material.alpha = params[:alpha_max].to_f.clamp(0.05,1.0)
        face.material = material; face.back_material = material
        mapping = [p00, Geom::Point3d.new(0,0,1), p10, Geom::Point3d.new(1,0,1), p01, Geom::Point3d.new(0,1,1)]
        face.position_material(material, mapping, true)
        face.position_material(material, mapping, false)
        face.edges.each { |edge| edge.hidden = true if edge.valid? }
        { created: 1, materials: [material], texture_path: path }
      end

      # Atualiza só materiais já existentes: é instantâneo e permite preview
      # ao vivo de cor/intensidade sem reconstruir a malha do letreiro.
      def self.update_backlight_appearance(group, params)
        intensity = params[:alpha_max].to_f.clamp(0.05, 1.0)
        previous_intensity = group.get_attribute(ATTR_DICT, 'alpha_max', 0.85).to_f.clamp(0.05, 1.0)
        rgb = params[:rgb_custom].is_a?(Array) ? params[:rgb_custom].map { |n| n.to_i.clamp(0,255) } : PRESETS.fetch(params[:preset].to_s, PRESETS['quente'])
        if group.get_attribute(ATTR_DICT, 'backlight_renderer') == 'texture'
          face = group.entities.grep(Sketchup::Face).first
          material = face && face.material
          if material
            material.color = Sketchup::Color.new(*rgb)
            material.colorize_type = Sketchup::Material::COLORIZE_TINT if material.respond_to?(:colorize_type=)
            material.alpha = intensity
          end
          group.set_attribute(ATTR_DICT, 'alpha_max', intensity)
          group.set_attribute(ATTR_DICT, 'preset', params[:preset].to_s)
          group.set_attribute(ATTR_DICT, 'rgb_custom', JSON.generate(params[:rgb_custom]))
          Sketchup.active_model.active_view.invalidate
          return
        end
        seen = {}
        group.entities.grep(Sketchup::Face).each do |face|
          band = face.get_attribute(ATTR_DICT, 'backlight_band', nil)
          material = face.material
          next unless material && !seen[material.object_id]
          # Compatibilidade com halos criados antes da gravação da banda.
          band ||= [[((material.alpha.to_f / previous_intensity) * 14.0).round - 1, 0].max, 13].min
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = ((band.to_i + 1).to_f / 14.0 * intensity).clamp(0.02, 1.0)
          seen[material.object_id] = true
        end
        group.set_attribute(ATTR_DICT, 'alpha_max', intensity)
        group.set_attribute(ATTR_DICT, 'preset', params[:preset].to_s)
        group.set_attribute(ATTR_DICT, 'rgb_custom', JSON.generate(params[:rgb_custom]))
        Sketchup.active_model.active_view.invalidate
      end

      # group.entityID => [largura, queda] usados na última reconstrução.
      # Cor/intensidade não mudam a malha (update_backlight_appearance
      # resolve isso sem reconstruir nada), mas largura/queda mudam o raio e
      # o formato do halo — isso SIM é geometria, então precisa reconstruir
      # a malha quando algum dos dois muda no preview ao vivo.
      @backlight_geo_cache = {}

      # Reconstrói (ou só retinta) o halo de um grupo existente, usado pelo
      # preview ao vivo de "Criar Letreiro" e, quando as faces originais
      # ainda são localizáveis (ver find_backlight_source_faces), também
      # pela edição de um backlight já criado.
      def self.rebuild_backlight(model, group, faces, params, prev_mats = nil, preview: false)
        return prev_mats || [] unless group.valid?

        render_params = preview ? Core.preview_params(params, :backlight) : params
        geo_key = [render_params[:halo_radius_cm].to_f, render_params[:halo_falloff].to_f,
                   render_params[:halo_bands].to_i, render_params[:halo_pixels].to_i]
        if prev_mats && !prev_mats.empty? && @backlight_geo_cache[group.entityID] == geo_key
          update_backlight_appearance(group, render_params)
          return prev_mats
        end

        group.entities.clear!
        if prev_mats && !prev_mats.empty?
          prev_mats.each { |m| model.materials.remove(m) rescue nil }
        end
          result = build_backlight_geo(group.entities, faces, render_params, model)
        raise 'Não foi possível gerar o halo.' if result[:created] == 0
          group.set_attribute(ATTR_DICT, 'backlight_renderer', 'native')
        @backlight_geo_cache[group.entityID] = geo_key
        model.active_view.invalidate
        result[:materials] || []
      end

      # Tenta reencontrar as faces originais do letreiro a partir dos
      # persistent_id salvos na criação (Sketchup::Entity#persistent_id,
      # disponível desde o SketchUp 2020 — sobrevive a salvar/reabrir o
      # arquivo, mesmo se a face estiver dentro de grupos/componentes
      # aninhados). Retorna [] se não achar nada (arquivo antigo sem essa
      # informação salva, ou o texto original foi apagado/alterado depois)
      # — nesse caso a edição cai de volta no modo só-cor/intensidade.
      def self.find_backlight_source_faces(model, group)
        raw = group.get_attribute(ATTR_DICT, 'source_face_pids', nil)
        return [] unless raw
        pids = Core.json_array(raw, max_items: 10_000)
        return [] unless pids.is_a?(Array) && !pids.empty?
        return [] unless pids.all? { |pid| pid.is_a?(Integer) && pid.positive? }
        found = model.find_entity_by_persistent_id(pids)
        (found || []).compact.select { |e| e.is_a?(Sketchup::Face) && e.valid? }
      rescue
        []
      end

      def self.create_backlight(model, faces, params)
        model.start_operation('K.Light — Criar Letreiro', true)
        group = model.active_entities.add_group
        group.name = 'K.Light_Letreiro'
        group.layer = Core.ensure_tag(model)
          result = build_backlight_geo(group.entities, faces, params, model)
        raise 'Não foi possível gerar o halo.' if result[:created] == 0
        group.set_attribute(ATTR_DICT, 'kind', 'backlight')
          group.set_attribute(ATTR_DICT, 'backlight_renderer', 'native')
        update_backlight_appearance(group, params)
        group.set_attribute(ATTR_DICT, 'version', PLUGIN_VERSION)
        model.commit_operation
        model.selection.clear; model.selection.add(group)
        model.active_view.invalidate
      rescue => err
        model.abort_operation rescue nil
        UI.messagebox("K.Light Letreiro: #{err.message}")
      end

    # BACKLIGHT — monta a malha uma única vez e, depois disso, o preview troca
    # somente materiais. Cor e intensidade respondem ao vivo sem travamento.
    #
    # Voltou a usar o raster (build_backlight_geo) depois de testar a técnica
    # de contorno (mesma da fita de LED aplicada a letras): em texto real o
    # contorno saiu pior que o raster — halo torto/flutuando fora do plano em
    # curvas e sumindo em letras inteiras. O raster ainda serrilha em curvas
    # fechadas, mas é o resultado mais confiável hoje. Resolução (128→200) e
    # nº de faixas (14→24) já foram aumentados antes pra suavizar um pouco o
    # serrilhado, sem trocar de técnica.
    def self.cmd_create_backlight
      model = Sketchup.active_model
      faces = model.selection.grep(Sketchup::Face)
      if faces.empty?
        UI.messagebox("K.Light: selecione as faces frontais do letreiro antes de criar o Letreiro.\n\n" \
                      "Entre no grupo do texto com duplo clique, selecione todas as letras e tente novamente.")
        return
      end
      preview_group = nil
      prev_mats     = nil
      # halo_radius_cm: alcance do halo (largura, igual a fita de LED).
      # halo_falloff: o quão rápido o brilho cai da borda pro fundo — mais
      # alto = mais concentrado na borda; mais baixo = degradê mais suave e
      # espalhado. Salvamos o persistent_id de cada face selecionada — se o
      # SketchUp conseguir reencontrá-las depois (mesmo dentro de grupos
      # aninhados), a edição consegue reconstruir a malha e ajustar largura/
      # queda de novo; se não conseguir (arquivo muito antigo, ou texto
      # original apagado), a edição cai pra só cor/intensidade.
      default_p = { alpha_max: 0.85, preset: 'quente', rgb_custom: nil,
                    halo_radius_cm: 8.0, halo_falloff: 4.0 }
      persist = lambda do |p|
        preview_group.set_attribute(ATTR_DICT, 'kind', 'backlight')
            preview_group.set_attribute(ATTR_DICT, 'backlight_renderer', 'native')
        preview_group.set_attribute(ATTR_DICT, 'halo_radius_cm', p[:halo_radius_cm].to_f)
        preview_group.set_attribute(ATTR_DICT, 'halo_falloff', p[:halo_falloff].to_f)
        preview_group.set_attribute(ATTR_DICT, 'source_face_pids', JSON.generate(faces.map(&:persistent_id)))
        preview_group.set_attribute(ATTR_DICT, 'version', PLUGIN_VERSION)
      end
      Dialog.show(
        ->(p) {
          if preview_group&.valid?
            prev_mats = rebuild_backlight(model, preview_group, faces, p, prev_mats)
            persist.call(p)
            model.commit_operation
            model.selection.clear; model.selection.add(preview_group)
          end
        },
        -> { model.abort_operation if preview_group }, nil,
        ->(p) { prev_mats = rebuild_backlight(model, preview_group, faces, p, prev_mats, preview: true) if preview_group&.valid? },
        init: { tab: 'backlight' },
        # UI.start_timer(0): o cálculo do halo (campo de distância + malha)
        # roda no mesmo processo/thread da interface do SketchUp — se
        # começasse direto aqui, dentro do próprio dialog_ready, a janela
        # ficava travada sem terminar de pintar (o botão "Criar Letreiro"
        # só aparecia depois que o cálculo acabasse). Adiando 1 tick, a
        # janela termina de desenhar primeiro e o cálculo roda logo em
        # seguida, sem bloquear a pintura.
        on_ready: -> {
          UI.start_timer(0, false) do
            begin
              model.start_operation('K.Light — Criar Letreiro', true)
              preview_group = model.active_entities.add_group
              preview_group.name = 'K.Light_Letreiro'
              preview_group.layer = Core.ensure_tag(model)
              prev_mats = rebuild_backlight(model, preview_group, faces, default_p, nil, preview: true)
              persist.call(default_p)
              model.active_view.invalidate
            rescue => err
              model.abort_operation rescue nil
              UI.messagebox("K.Light Letreiro: #{err.message}")
            end
          end
        }
      )
    end

    end # Letreiro
  end
end
