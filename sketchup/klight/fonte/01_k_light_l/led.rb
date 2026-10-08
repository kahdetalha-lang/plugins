module KahDetalha
  module KLight
    module Led

      # -----------------------------------------------------------------------
      # OTIMIZAÇÃO DE LINHAS — Douglas-Peucker sobre o trajeto já extraído.
      # Curvas orgânicas/freehand costumam vir com dezenas de pontos quase
      # colineares (segmentos minúsculos demais pra fazer diferença visual).
      # Isso alimenta smooth_laterals/vertical_safe_laterals com tangentes
      # quase-zero em sequência, exatamente o tipo de instabilidade numérica
      # que abre espinhos na malha da fita. Simplificar o trajeto ANTES de
      # calcular normais/laterais remove esse ruído sem mudar a forma da
      # curva visivelmente (a tolerância é uma distância máxima de desvio).
      #
      # Aplicada automaticamente quando o trajeto tem muitos pontos (curva
      # complexa/orgânica) e, além disso, disponível como botão manual
      # "Otimizar Linhas" no painel do LED, com tolerância mais forte.
      AUTO_SIMPLIFY_MIN_POINTS  = 40
      AUTO_SIMPLIFY_TOLERANCE   = 0.05 # ~1.3mm — limpeza leve, quase imperceptível
      STRONG_SIMPLIFY_TOLERANCE = 0.2  # ~5mm — modo manual "Otimizar Linhas"

      # Distância perpendicular de um ponto a uma reta (para Douglas-Peucker).
      def self.perp_distance(point, line_start, line_end)
        return point.distance(line_start) if line_start == line_end
        v    = line_end - line_start
        w    = point - line_start
        len2 = v.length**2
        t    = (v % w) / len2
        t    = [[t, 0.0].max, 1.0].min
        proj = line_start.offset(v, t * v.length)
        point.distance(proj)
      end

      # Douglas-Peucker ITERATIVO (pilha explícita, não recursão Ruby):
      # mantém só os pontos necessários pra ficar dentro de `tolerance`
      # (polegadas) de desvio em relação à curva original.
      #
      # Era recursivo antes — cada nível de recursão empilha um frame na
      # pilha de chamadas do Ruby embutido no SketchUp, que tem um limite
      # bem mais baixo que um MRI standalone. Numa curva quase reta com
      # milhares de pontos (o pior caso: cada chamada só consegue "resolver"
      # um ponto por vez), a profundidade de recursão se aproximava do total
      # de pontos selecionados — até MAX_EDGES (4000) — arriscando um
      # estouro de pilha e o "bug splash" do SketchUp. Usando uma pilha
      # (Array) no heap em vez do call stack, a profundidade deixa de ser um
      # limite: o custo vira só memória, não risco de crash.
      def self.douglas_peucker(points, tolerance)
        n = points.length
        return points if n < 3

        keep = Array.new(n, false)
        keep[0] = true
        keep[n - 1] = true

        stack = [[0, n - 1]]
        until stack.empty?
          first, last = stack.pop
          next if last - first < 2

          dmax  = 0.0
          index = 0
          (first + 1...last).each do |i|
            d = perp_distance(points[i], points[first], points[last])
            if d > dmax
              index = i
              dmax  = d
            end
          end

          next unless dmax > tolerance

          keep[index] = true
          stack << [first, index]
          stack << [index, last]
        end

        points.each_with_index.select { |_, i| keep[i] }.map(&:first)
      end

      # Wrapper seguro: não simplifica trajetos já curtos, e nunca devolve
      # menos de 2 pontos (o mínimo pra existir uma fita).
      def self.simplify_path(points, tolerance)
        return points if points.size < 3 || tolerance.to_f <= 0
        simplified = douglas_peucker(points, tolerance.to_f)
        simplified.size >= 2 ? simplified : points
      end

      # Troca as arestas quebradas originais por UMA curva contínua só, com
      # os pontos (já otimizados) do trajeto — mesmo comportamento do
      # organic_curve_tool.rb standalone. Chamado só na CRIAÇÃO (não durante
      # o preview ao vivo), senão ficaria apagando/recriando geometria a
      # cada tick de slider.
      def self.replace_edges_with_curve(edges, points)
        return if points.size < 2
        valid_edges = edges.select(&:valid?)
        return if valid_edges.empty?
        entities = valid_edges.first.parent.entities
        valid_edges.each { |e| e.erase! if e.valid? }
        entities.add_curve(points)
      rescue
        nil
      end

      def self.world_transform(model)
        path = model.active_path
        return Geom::Transformation.new if path.nil? || path.empty?
        path.reduce(Geom::Transformation.new) { |t, inst| t * inst.transformation }
      end

      # -----------------------------------------------------------------------
      # EDGES_TO_PATH — vertex.entityID como chave
      # -----------------------------------------------------------------------
      def self.edges_to_path(edges)
        return [] if edges.empty?

        expanded = {}
        edges.each do |e|
          next unless e.valid?
          if e.respond_to?(:curve) && e.curve
            e.curve.edges.each { |ce| expanded[ce.entityID] = ce if ce.valid? }
          else
            expanded[e.entityID] = e
          end
        end
        all_edges = expanded.values
        return [] if all_edges.empty?

        if all_edges.size > Core::MAX_EDGES
          UI.messagebox("K.Light: a seleção tem #{all_edges.size} arestas, " \
                        "acima do limite seguro de #{Core::MAX_EDGES}.\n\n" \
                        "Simplifique a curva (reduza segmentos) antes de criar a faixa.")
          return []
        end

        # Keep only the largest connected component. This prevents a branch or
        # accidental extra selected edge from stopping the path walk early.
        all_edges = largest_connected_component(all_edges)
        return [] if all_edges.empty?

        adj           = Hash.new { |h, k| h[k] = [] }
        vid_to_vertex = {}
        all_edges.each do |e|
          next unless e.valid?
          sv = e.start; ev = e.end
          vid_to_vertex[sv.entityID] = sv
          vid_to_vertex[ev.entityID] = ev
          adj[sv.entityID] << [e, ev]
          adj[ev.entityID] << [e, sv]
        end

        return [] if adj.empty?

        start_vid = (adj.find { |_, c| c.size == 1 } || adj.first)[0]
        visited   = {}
        path      = [start_vid]
        cur       = start_vid

        loop do
          opts = adj[cur].reject { |e, _| !e.valid? || visited[e.entityID] }
          break if opts.empty?
          edge, nxt = best_next_edge(opts, cur, path, vid_to_vertex)
          visited[edge.entityID] = true
          path << nxt.entityID
          cur = nxt.entityID
        end

        path.map { |vid| vid_to_vertex[vid].position }
      end

      # -----------------------------------------------------------------------
      # COMPONENTE CONEXA — Union-Find (Disjoint Set), O(n) na prática.
      # A versão anterior usava Array#partition dentro de um loop, varrendo
      # todas as arestas restantes a cada passo (O(n²)). Em curvas com muitos
      # segmentos isso travava o Ruby por tempo suficiente para o SketchUp
      # disparar o bug splash. Union-Find resolve isso com custo quase linear.
      # -----------------------------------------------------------------------
      def self.largest_connected_component(edges)
        return [] if edges.empty?

        parent = {}
        find = lambda do |x|
          while parent[x] && parent[x] != x
            parent[x] = parent[parent[x]] || parent[x] # path halving
            x = parent[x]
          end
          x
        end
        union = lambda do |a, b|
          ra = find.call(a); rb = find.call(b)
          parent[ra] = rb unless ra == rb
        end

        edges.each do |e|
          next unless e.valid?
          sid = e.start.entityID
          eid = e.end.entityID
          parent[sid] ||= sid
          parent[eid] ||= eid
          union.call(sid, eid)
        end

        groups = Hash.new { |h, k| h[k] = [] }
        edges.each do |e|
          next unless e.valid?
          root = find.call(e.start.entityID)
          groups[root] << e
        end

        groups.values.max_by(&:size) || []
      end

      def self.share_vertex?(a, b)
        a.start.entityID == b.start.entityID ||
          a.start.entityID == b.end.entityID ||
          a.end.entityID == b.start.entityID ||
          a.end.entityID == b.end.entityID
      end

      def self.best_next_edge(options, cur_vid, path, vid_to_vertex)
        return options.first if path.size < 2 || options.size == 1

        cur_pt = vid_to_vertex[cur_vid].position
        prev_pt = vid_to_vertex[path[-2]].position
        prev_vec = cur_pt - prev_pt
        return options.first if prev_vec.length < 1e-10
        prev_vec.normalize!

        options.max_by do |edge, nxt|
          next_vec = nxt.position - cur_pt
          next_vec.length < 1e-10 ? -2.0 : prev_vec.dot(next_vec.normalize)
        end
      end

      # -----------------------------------------------------------------------
      # NORMAL automática
      # -----------------------------------------------------------------------
      def self.detect_normal(edges, model, path_pts = nil)
        all_edges = []
        edges.each do |e|
          next unless e.valid?
          if e.respond_to?(:curve) && e.curve
            all_edges.concat(e.curve.edges.select(&:valid?))
          else
            all_edges << e
          end
        end

        face_scores = Hash.new(0.0)
        all_edges.each do |edge|
          edge.faces.each do |face|
            next unless face.valid?
            face_scores[face] += edge.length.to_f
          end
        end

        unless face_scores.empty?
          support_face, = face_scores.max_by do |face, length_score|
            normal = face.normal
            horizontal_bias = normal.z.abs * length_score * 0.35
            length_score + horizontal_bias
          end

          n = support_face.normal.normalize
          cam_dir = (model.active_view.camera.eye -
                     all_edges.first.start.position).normalize
          n = n.reverse if n.dot(cam_dir) < 0
          return n
        end

        # Sem face de apoio (caso comum: linha solta, sem geometria embaixo).
        # MÉTODO DE NEWELL — soma a contribuição de TODOS os segmentos do
        # trajeto (na ordem real da curva) em vez de tirar o produto vetorial
        # de só 2 pontos "escolhidos a dedo". Isso é muito mais estável
        # numericamente: numa curva com vários trechos quase colineares
        # (retas longas, por exemplo), pegar só 2 pontos pode dar um produto
        # vetorial quase degenerado cuja DIREÇÃO já sai dominada por ruído de
        # ponto flutuante — não só a magnitude. Com Newell, cada segmento
        # contribui um pouco, e a soma cancela ruído em vez de amplificar.
        ordered = path_pts && path_pts.size >= 3 ? path_pts : nil
        ordered ||= begin
          pts = all_edges.flat_map { |e| [e.start.position, e.end.position] }.uniq
          pts.size >= 3 ? pts : nil
        end

        if ordered
          nx = ny = nz = 0.0
          (0...ordered.size - 1).each do |i|
            p0 = ordered[i]; p1 = ordered[i+1]
            nx += (p0.y - p1.y) * (p0.z + p1.z)
            ny += (p0.z - p1.z) * (p0.x + p1.x)
            nz += (p0.x - p1.x) * (p0.y + p1.y)
          end
          n = Geom::Vector3d.new(nx, ny, nz)

          if n.length > 1e-6
            cam_dir = (model.active_view.camera.eye - ordered.first).normalize
            n = n.reverse if n.dot(cam_dir) < 0
            return n.normalize
          end
        end

        cam = model.active_view.camera
        (cam.eye - cam.target).normalize
      end

      # -----------------------------------------------------------------------
      # LATERAIS suavizadas
      # -----------------------------------------------------------------------
      def self.smooth_laterals(path_pts, face_normal)
        n            = path_pts.size
        lats         = Array.new(n)
        # Contorno fechado (ex.: laço de uma letra vindo de Face#loops): o
        # primeiro e o último ponto são o MESMO lugar fisicamente. Sem tratar
        # esse caso, os dois extremos do array calculavam a lateral usando só
        # o segmento de UM lado (faltando o vizinho "do outro lado da
        # costura"), e podiam sair com direções diferentes no mesmo ponto —
        # abrindo uma rachadura/espinho na malha bem na costura do laço.
        closed       = n > 2 && (path_pts.first - path_pts.last).length < 1e-4
        seg_tangents = (0...n-1).map do |i|
          t = path_pts[i+1] - path_pts[i]
          t.length > 1e-10 ? t.normalize : nil
        end

        (0...n).each do |i|
          tans = []
          if i > 0
            tans << seg_tangents[i-1] if seg_tangents[i-1]
          elsif closed && seg_tangents[n-2]
            tans << seg_tangents[n-2] # costura: vizinho "antes" é o último segmento do laço
          end
          if i < n-1
            tans << seg_tangents[i] if seg_tangents[i]
          elsif closed && seg_tangents[0]
            tans << seg_tangents[0] # costura: vizinho "depois" é o primeiro segmento do laço
          end
          next if tans.empty?
          tx = tans.sum(&:x)/tans.size
          ty = tans.sum(&:y)/tans.size
          tz = tans.sum(&:z)/tans.size
          avg = Geom::Vector3d.new(tx, ty, tz)
          # |avg| = média de dois vetores UNITÁRIOS: cai perto de 0 quando os
          # dois segmentos vizinhos quase se dobram sobre si mesmos (uma
          # reentrância/cúspide bem fechada). Nessa faixa, a direção da média
          # passa a depender de diferenças numéricas minúsculas entre os dois
          # segmentos — instável o bastante pra apontar em qualquer direção,
          # inclusive "pra fora" da curva (o espinho). 0.3 cobre reentrâncias
          # a partir de ~145° de fechamento; abaixo disso, cai pro vizinho
          # estável já calculado (facetado ali, mas nunca instável).
          next if avg.length < 0.3
          lat = face_normal.cross(avg.normalize)
          lats[i] = lat.normalize if lat.length > 1e-10
        end

        (1...n).each    { |i| lats[i] ||= lats[i-1] }
        (n-2).downto(0) { |i| lats[i] ||= lats[i+1] }
        # Os dois lados da costura recebem os MESMOS dois vizinhos acima, então
        # já deveriam coincidir — força a igualdade pra eliminar qualquer
        # resíduo de arredondamento entre eles.
        lats[n-1] = lats[0] if closed
        lats
      end

      # -----------------------------------------------------------------------
      # LATERAIS "CIMA"/"BAIXO" — seguras para trechos verticais
      # -----------------------------------------------------------------------
      # O modo Cima/Baixo antigo usava um vetor mundial fixo (0,0,1) ou
      # (0,0,-1) para TODOS os pontos da curva, sem checar se esse vetor era
      # perpendicular ao trajeto. Numa linha com trechos quase verticais
      # (reta subindo, por exemplo), a direção da largura da fita ficava
      # quase PARALELA ao próprio trajeto em vez de perpendicular — o quad
      # da fita colapsava/torcia e o SketchUp fundia tudo numa mancha.
      #
      # Aqui projetamos o vetor desejado (cima/baixo) no plano perpendicular
      # à tangente local do trajeto. Isso mantém o efeito "sempre pra cima/
      # baixo" em todo trecho onde isso faz sentido geometricamente, e só
      # cai de volta no lateral automático (perpendicular real à curva)
      # nos poucos pontos onde o trajeto está praticamente vertical — onde
      # "cima/baixo" deixa de ter um perpendicular bem definido.
      #
      # IMPORTANTE: o lateral automático de fallback tem sinal arbitrário
      # (não sabe se "está do lado de cima ou de baixo" da fita) — então a
      # cada ponto a gente garante continuidade escolhendo o lado mais
      # próximo do lateral anterior. Sem isso, o modo "Baixo" virava de
      # lado bem nos trechos quase-verticais (onde o fallback entra),
      # colapsando os triângulos exatamente ali — era isso que sumia nos
      # trechos retos.
      def self.vertical_safe_laterals(path_pts, desired, auto_laterals)
        n            = path_pts.size
        # Mesmo cuidado de smooth_laterals: contorno fechado tem o primeiro e
        # o último ponto no mesmo lugar — sem envolver a busca de vizinhos na
        # costura, os dois extremos podiam sair com laterais diferentes no
        # mesmo ponto.
        closed       = n > 2 && (path_pts.first - path_pts.last).length < 1e-4
        seg_tangents = (0...n-1).map do |i|
          t = path_pts[i+1] - path_pts[i]
          t.length > 1e-10 ? t.normalize : nil
        end

        prev = nil

        lats = Array.new(n) do |i|
          lat =
            begin
              tans = []
              if i > 0
                tans << seg_tangents[i-1] if seg_tangents[i-1]
              elsif closed && seg_tangents[n-2]
                tans << seg_tangents[n-2]
              end
              if i < n-1
                tans << seg_tangents[i] if seg_tangents[i]
              elsif closed && seg_tangents[0]
                tans << seg_tangents[0]
              end

              if tans.empty?
                auto_laterals[i]
              else
                tx = tans.sum(&:x)/tans.size
                ty = tans.sum(&:y)/tans.size
                tz = tans.sum(&:z)/tans.size
                avg = Geom::Vector3d.new(tx, ty, tz)

                # Mesmo raciocínio de smooth_laterals: abaixo desse limiar a
                # direção da média fica instável perto de uma reentrância bem
                # fechada. auto_laterals[i] já é o valor estável calculado lá
                # (com essa mesma proteção), então é um fallback seguro aqui.
                if avg.length < 0.3
                  auto_laterals[i]
                else
                  avgn = avg.normalize
                  d    = desired.dot(avgn)
                  proj = Geom::Vector3d.new(desired.x - avgn.x * d,
                                             desired.y - avgn.y * d,
                                             desired.z - avgn.z * d)

                  # < ~15% do comprimento unitário = trajeto quase paralelo
                  # ao vetor desejado. Não dá pra extrair uma largura
                  # perpendicular confiável daqui — usa o lateral
                  # automático nesse ponto (o bloco de continuidade abaixo
                  # corrige o sinal dele).
                  proj.length < 0.15 ? auto_laterals[i] : proj.normalize
                end
              end
            end

          if lat
            # Trava de continuidade: nunca deixa o lateral virar de lado
            # de um ponto pro outro (o que criaria uma faixa torcida).
            lat = lat.reverse if prev && lat.dot(prev) < 0
            prev = lat
          end

          lat
        end

        # Mesmo ajuste de smooth_laterals: os dois lados da costura usam os
        # mesmos vizinhos acima, então já deveriam coincidir — mas a trava de
        # continuidade sequencial (prev/reverse) não garante isso sozinha
        # numa volta fechada, então força a igualdade no final.
        lats[n-1] = lats[0] if closed
        lats
      end

      # Mesma ideia de vertical_safe_laterals (fita sempre "pra cima/baixo"),
      # mas por SEGMENTO em vez de por vértice — cada segmento só tem UMA
      # tangente, não precisa de média com o vizinho.
      #
      # v1 desse helper trocava "na marra" entre a fórmula vertical e o
      # fallback automático num limiar fixo, mais uma trava que invertia o
      # sinal comparando com o segmento anterior. Isso criava um salto de
      # direção bem onde a tangente passa perto do próprio "desired"
      # (lateral de curvas com eixo vertical) — a comparação com "o segmento
      # anterior" não tem por que valer aqui, já que cada segmento tem sua
      # própria tangente bem definida. Agora cada segmento MISTURA as duas
      # direções suavemente, proporcional a quão bem-definida a projeção
      # vertical está ali — função contínua da tangente local, sem depender
      # de nenhum vizinho, então não há salto possível.
      def self.vertical_safe_seg_laterals(wpts, desired, auto_seg_laterals)
        n_segs = wpts.size - 1

        Array.new(n_segs) do |i|
          auto_dir = auto_seg_laterals[i]
          tangent  = wpts[i+1] - wpts[i]
          next auto_dir if tangent.length < 1e-10 || auto_dir.nil?

          tn   = tangent.normalize
          d    = desired.dot(tn)
          proj = Geom::Vector3d.new(desired.x - tn.x * d,
                                     desired.y - tn.y * d,
                                     desired.z - tn.z * d)
          plen = proj.length
          next auto_dir if plen < 1e-6

          proj_dir = proj.normalize
          # Alinha o sinal do fallback ao da projeção (sempre bem definida
          # aqui, plen > 0) antes de misturar — evita que a mistura em si
          # vire uma média de dois vetores quase opostos.
          auto_dir = auto_dir.reverse if auto_dir.dot(proj_dir) < 0

          # Peso 0 → puro fallback (tangente quase paralela ao "desired",
          # projeção pouco confiável). Peso 1 → pura projeção vertical
          # (tangente bem perpendicular ao "desired"). Transição suave
          # entre os dois num intervalo, não um degrau num ponto só.
          w = [[plen / 0.3, 1.0].min, 0.0].max
          blended = Geom::Vector3d.new(
            auto_dir.x * (1 - w) + proj_dir.x * w,
            auto_dir.y * (1 - w) + proj_dir.y * w,
            auto_dir.z * (1 - w) + proj_dir.z * w)
          blended.length > 1e-10 ? blended.normalize : auto_dir
        end
      end

      # -----------------------------------------------------------------------
      # CRIAÇÃO DA RIBBON
      # -----------------------------------------------------------------------
      # RIBBON: helpers compartilhados entre criação e live preview
      # -----------------------------------------------------------------------

      # Para trajetos FECHADOS (laço), garante que os laterais "base" (antes
      # do toggle Fora/Dentro do usuário) apontem de fato pra FORA do laço.
      #
      # edges_to_path caminha aresta a aresta a partir de um vértice
      # ESCOLHIDO ARBITRARIAMENTE (o primeiro do Hash de adjacência, quando
      # não há ponta solta) e pode percorrer o laço tanto no sentido horário
      # quanto no anti-horário — sem padronizar isso, o sinal de
      # face_normal.cross(tangente) saía correto (pra fora) em alguns laços e
      # invertido (pra dentro) em outros, dependendo só da ordem de iteração
      # interna do Ruby. Era exatamente isso que fazia "Fora" gerar luz pra
      # dentro em várias arestas: o bug não estava em qual lado reverter, e
      # sim no sinal-base em si ser ambíguo por laço.
      #
      # Corrige comparando o lateral de UM ponto de amostra com o vetor até o
      # centroide do laço: se aponta no mesmo sentido do centroide (ou seja,
      # pra DENTRO), inverte todos os laterais de uma vez.
      def self.ensure_outward_laterals!(wpts, laterals, closed)
        return unless closed && wpts.size > 2

        sample_i = (0...wpts.size).find { |i| laterals[i] }
        return unless sample_i

        cx = wpts.sum(&:x) / wpts.size
        cy = wpts.sum(&:y) / wpts.size
        cz = wpts.sum(&:z) / wpts.size
        centroid = Geom::Point3d.new(cx, cy, cz)

        to_centroid = centroid - wpts[sample_i]
        return if to_centroid.length.to_f < 1e-9

        return unless laterals[sample_i].dot(to_centroid.normalize) > 0

        laterals.map! { |lat| lat ? lat.reverse : nil }
      end

      # Calcula trajeto, normais e laterais a partir das arestas selecionadas.
      # Retorna um hash ou nil se o caminho for inválido.
      #
      # override_normal: usado na EDIÇÃO. As arestas usadas para recalcular
      # o trajeto ali são segmentos temporários soltos (sem face adjacente
      # no modelo), então detect_normal não tem como reconhecer a superfície
      # original e cai no método de aproximação (Newell) — que é razoável
      # pra retas mas pode errar bastante em curvas orgânicas/3D, jogando o
      # offset da faixa pra dentro do sólido (some visualmente) ou pra uma
      # direção estranha. Passando a normal já salva no grupo desde a
      # criação, a edição fica fiel à orientação original, curva ou reta.
      def self.ribbon_prep(model, edges, override_normal: nil, force_optimize: false)
        path_pts = edges_to_path(edges)
        return nil if path_pts.size < 2

        # Otimização automática pra curvas com muitos pontos (freehand/
        # orgânica), ou forçada pelo botão "Otimizar Linhas" do painel —
        # nesse caso com tolerância mais forte, já que foi um pedido
        # explícito do usuário.
        if force_optimize || path_pts.size > AUTO_SIMPLIFY_MIN_POINTS
          tol = force_optimize ? STRONG_SIMPLIFY_TOLERANCE : AUTO_SIMPLIFY_TOLERANCE
          path_pts = simplify_path(path_pts, tol)
        end
        return nil if path_pts.size < 2

        xform = world_transform(model)

        # override_normal já vem em coordenadas de mundo (foi salvo a partir
        # de um prep[:face_normal] anterior, que já passou por esse mesmo
        # transform na criação). Reaplicar o xform em cima dele duplicaria a
        # transformação — só a normal recém-detectada (em coordenadas locais
        # do contexto das arestas) precisa desse passo.
        if override_normal
          face_normal = override_normal
        else
          face_normal = detect_normal(edges, model, path_pts)
          unless xform.identity?
            origin = xform * Geom::Point3d.new(0, 0, 0)
            tip    = xform * Geom::Point3d.new(face_normal.x, face_normal.y, face_normal.z)
            face_normal = (tip - origin).normalize
          end
        end

        wpts      = path_pts.map { |p| xform * p }
        auto_lats = smooth_laterals(wpts, face_normal)

        if auto_lats.compact.empty?
          cands = [Geom::Vector3d.new(0,0,1), Geom::Vector3d.new(1,0,0), Geom::Vector3d.new(0,1,0)]
          fb = cands.map { |c| face_normal.cross(c) }.find { |v| v.length > 1e-6 }
          fb = fb ? fb.normalize : Geom::Vector3d.new(1, 0, 0)
          auto_lats = Array.new(wpts.size) { fb }
        end

        closed = wpts.size > 2 && (wpts.first - wpts.last).length < 1e-4
        ensure_outward_laterals!(wpts, auto_lats, closed)

        { wpts: wpts, auto_lats: auto_lats, face_normal: face_normal, path_pts: path_pts }
      end

      # Edição segura: reconstrói o preparo diretamente dos pontos já salvos
      # no grupo K.Light. Não cria arestas temporárias no modelo — criar uma
      # linha sobre uma face existente pode dividi-la ou apagá-la no SketchUp.
      def self.ribbon_prep_from_world_points(model, points, saved_normal = nil)
        wpts = points.select { |p| p.is_a?(Geom::Point3d) }
        return nil if wpts.size < 2
        face_normal = saved_normal || (model.active_view.camera.eye - model.active_view.camera.target).normalize
        face_normal = face_normal.normalize
        auto_lats = smooth_laterals(wpts, face_normal)
        if auto_lats.compact.empty?
          cands = [Geom::Vector3d.new(0,0,1), Geom::Vector3d.new(1,0,0), Geom::Vector3d.new(0,1,0)]
          fallback = cands.map { |c| face_normal.cross(c) }.find { |vec| vec.length > 1e-6 }
          auto_lats = Array.new(wpts.size) { fallback ? fallback.normalize : Geom::Vector3d.new(1,0,0) }
        end
        closed = wpts.size > 2 && (wpts.first - wpts.last).length < 1e-4
        ensure_outward_laterals!(wpts, auto_lats, closed)
        { wpts: wpts, auto_lats: auto_lats, face_normal: face_normal, path_pts: wpts }
      end

      # -----------------------------------------------------------------------
      # RIBBON A PARTIR DE FACE — modo "Letreiro" (seleção por face, não por
      # arestas soltas)
      # -----------------------------------------------------------------------
      # Por que isso é mais robusto que o modo de arestas para letras/logos:
      # cada Face já entrega seus contornos (Face#loops: o externo + um por
      # furo, tipo o "olho" do A/R/O/D) NA ORDEM CERTA e com a NORMAL exata.
      # Isso elimina de vez a dependência da "maior componente conectada"
      # (que descartava letras inteiras da seleção) e da heurística de
      # detecção de normal — que só existiam porque, com arestas soltas, o
      # SketchUp não garante nem ordem nem qual face está "por baixo".
      def self.loop_to_closed_points(loop)
        pts = loop.vertices.map(&:position)
        return [] if pts.size < 3
        pts << pts.first # fecha o contorno (primeiro ponto repetido no fim)
        pts
      end

      def self.ribbon_prep_from_face_loop(model, face, loop, xform_override: nil)
        path_pts = loop_to_closed_points(loop)
        return nil if path_pts.size < 4 # 3 vértices únicos + fechamento

        xform       = xform_override || world_transform(model)
        face_normal = face.normal.normalize
        unless xform.identity?
          origin = xform * Geom::Point3d.new(0, 0, 0)
          tip    = xform * Geom::Point3d.new(face_normal.x, face_normal.y, face_normal.z)
          face_normal = (tip - origin).normalize
        end

        wpts      = path_pts.map { |p| xform * p }
        auto_lats = smooth_laterals(wpts, face_normal)

        if auto_lats.compact.empty?
          cands = [Geom::Vector3d.new(0,0,1), Geom::Vector3d.new(1,0,0), Geom::Vector3d.new(0,1,0)]
          fb = cands.map { |c| face_normal.cross(c) }.find { |v| v.length > 1e-6 }
          fb = fb ? fb.normalize : Geom::Vector3d.new(1, 0, 0)
          auto_lats = Array.new(wpts.size) { fb }
        end

        { wpts: wpts, auto_lats: auto_lats, face_normal: face_normal, path_pts: path_pts }
      end

      # Todas as faces selecionadas -> todos os loops (contorno + furos) de
      # cada uma -> um prep por loop. Uma palavra inteira selecionada por
      # face gera um prep por letra (e por furo de letra), sem perder nada.
      def self.faces_to_preps(model, faces)
        faces.uniq.flat_map do |face|
          next [] unless face.valid?
          face.loops.map { |lp| ribbon_prep_from_face_loop(model, face, lp) }.compact
        end
      end

      # Trajeto a partir de uma aresta que não fecha contorno de face: segue
      # as arestas ligadas em sequência pelos dois lados, parando em
      # bifurcação. Aresta clicada solta só aceita vizinhas soltas; encostada
      # em geometria (borda de prateleira), aceita qualquer vizinha.
      def self.wire_prep_from_edge(model, seed_edge, xform_override: nil)
        return nil unless seed_edge && seed_edge.valid?

        only_loose = seed_edge.faces.empty?
        chain = [seed_edge]
        seen  = { seed_edge.entityID => true }
        [seed_edge.start, seed_edge.end].each do |vertex|
          while chain.size < Core::MAX_EDGES
            nexts = vertex.edges.reject do |e|
              !e.valid? || seen[e.entityID] || (only_loose && !e.faces.empty?)
            end
            break unless nexts.size == 1

            edge = nexts.first
            seen[edge.entityID] = true
            chain << edge
            vertex = edge.other_vertex(vertex)
          end
        end

        local_pts = edges_to_path(chain)
        return nil if local_pts.size < 2

        xform = xform_override || world_transform(model)
        world = local_pts.map { |pt| xform * pt }

        normal = detect_normal(chain, model, local_pts).transform(xform)
        return nil if tiny?(normal)
        normal.normalize!
        to_eye = model.active_view.camera.eye - world.first
        normal.reverse! if !tiny?(to_eye) && normal.dot(to_eye) < 0

        # Numa reta paralela à normal detectada (ex.: linha solta no eixo
        # azul) todos os laterais saem nil — tudo bem: contour_frame resolve
        # o lado de cada segmento sozinho (segment_side).
        lats = smooth_laterals(world, normal)
        closed = world.size > 2 && world.first.distance(world.last) < 0.1.cm
        ensure_outward_laterals!(world, lats, closed)

        { wpts: world, auto_lats: lats, face_normal: normal, path_pts: world }
      rescue StandardError => error
        warn("K.Light aresta solta: #{error.message}")
        nil
      end

      # LED INTELIGENTE
      # A partir de uma aresta, encontra a face plana que a contém e usa o
      # loop inteiro daquela face como percurso. Não cria geometria auxiliar
      # sobre o modelo.
      def self.smart_loop_prep_from_edge(model, edge, xform_override: nil)
        return nil unless edge && edge.valid?

        candidates = edge.faces.select(&:valid?)
        return nil if candidates.empty?

        # A face maior normalmente é a face frontal que define o contorno.
        face = candidates.max_by(&:area)
        loop = face.loops.find { |candidate| candidate.edges.include?(edge) }
        return nil unless loop

        prep = ribbon_prep_from_face_loop(model, face, loop, xform_override: xform_override)
        return nil unless prep

        # Mantém a prévia voltada para quem está olhando o modelo.
        camera_vector = model.active_view.camera.eye - prep[:wpts].first
        if camera_vector.length > 1e-6 && prep[:face_normal].dot(camera_vector) < 0
          prep[:face_normal] = prep[:face_normal].reverse
          prep[:auto_lats] = smooth_laterals(prep[:wpts], prep[:face_normal])
        end

        ensure_outward_laterals!(prep[:wpts], prep[:auto_lats], true)
        prep
      end

      # Constrói toda a geometria da faixa dentro de `ge` (group.entities).
      # Não gerencia operações — o chamador é responsável por isso.
      # Retorna { created: N, edges: Hash }.
      # Cor/alpha de cada camada da fita — extraído do meio de build_ribbon_geo
      # pra poder ser reusado por retint_ribbon_materials (preview ao vivo
      # sem reconstruir a malha quando só cor/intensidade/queda mudam).
      def self.ribbon_layer_rgb(params)
        rgb_custom = params[:rgb_custom]
        if rgb_custom.is_a?(Array) && rgb_custom.size == 3
          rgb_custom.map { |v| v.to_i.clamp(0, 255) }
        else
          PRESETS.fetch(params[:preset].to_s, PRESETS['quente'])
        end
      end

      def self.ribbon_layer_alpha(l, n_layers, params)
        alpha_max = params[:alpha_max].to_f.clamp(0.05, 1.0)
        curve_exp = params[:curve_exp].to_f.clamp(0.5, 8.0)
        t = (l + 0.5) / n_layers.to_f
        (alpha_max * ((1.0 - t) ** curve_exp)).clamp(0.0, 1.0)
      end

      # Retinta materiais já existentes (mesmo nº de camadas) sem tocar na
      # malha — usado pelo preview ao vivo quando só cor/intensidade/queda
      # mudaram, evitando reconstruir geometria e recriar materiais a cada
      # tick de um slider.
      def self.retint_ribbon_materials(mats, params)
        r, g, b = ribbon_layer_rgb(params)
        n = mats.size
        mats.each_with_index do |mat, l|
          next unless mat.valid?
          mat.color = Sketchup::Color.new(r, g, b)
          mat.alpha = ribbon_layer_alpha(l, n, params)
        end
      end

      # -----------------------------------------------------------------------
      # GEOMETRIA DA FITA — utilidades
      # -----------------------------------------------------------------------

      # Geom::Vector3d#length devolve um Length, que compara com a tolerância
      # do SketchUp (~0,001"): `vetor_nulo.length < 1e-6` dá FALSE. Toda
      # checagem de vetor degenerado passa por aqui, em Float.
      def self.tiny?(vec)
        vec.length.to_f < 1e-6
      end

      def self.scaled(vec, factor)
        f = factor.to_f
        Geom::Vector3d.new(vec.x * f, vec.y * f, vec.z * f)
      end

      # Lateral unitário de UM segmento do trajeto. Tenta, em ordem:
      #   1. Cima/Baixo (vertical_dir) sem a componente ao longo do segmento;
      #   2. normal do plano × tangente;
      #   3. tangente × o eixo do modelo menos alinhado com ela.
      # O passo 3 cobre a reta solta no eixo azul, onde 1 e 2 dão vetor nulo.
      def self.segment_side(tangent, face_normal, vertical_dir)
        tries = []
        tries << vertical_dir - scaled(tangent, vertical_dir.dot(tangent)) if vertical_dir
        tries << face_normal.cross(tangent)
        least_aligned = [X_AXIS, Y_AXIS, Z_AXIS].min_by { |axis| axis.dot(tangent).abs }
        tries << tangent.cross(least_aligned)
        found = tries.find { |vec| !tiny?(vec) }
        found && found.normalize
      end

      # LED INTELIGENTE — faixa de largura constante ao redor do trajeto.
      #
      # Devolve { base:, push:, closed: }: `base` são os pontos onde a luz
      # nasce (trajeto + afastamento da superfície) e `push[i]` é o vetor
      # que leva base[i] até a borda externa da faixa. Nos vértices internos
      # o vetor segue a bissetriz dos laterais dos dois segmentos vizinhos,
      # sempre com comprimento `width`; todas as camadas usam os mesmos
      # vetores, então camadas transparentes nunca se sobrepõem nas quinas.
      def self.contour_frame(prep, width, direction_in: false,
                             vertical_mode: 'down', offset: 0.0)
        src_pts  = prep[:wpts]
        src_refs = prep[:auto_lats] || []
        return nil if src_pts.size < 2

        closed = src_pts.size > 2 && src_pts.first.distance(src_pts.last) < 0.1.cm

        # Pontos repetidos/colados geram segmentos sem direção — descarta
        # antes, mantendo o lateral de referência de cada ponto que fica.
        pts  = []
        refs = []
        src_pts.each_with_index do |pt, i|
          next if pts.any? && pts.last.distance(pt) < 0.02.cm
          pts  << pt.clone
          refs << (src_refs[i] && src_refs[i].clone)
        end
        if closed
          # Fecha exatamente no primeiro ponto (o último pode ter sido
          # descartado acima por estar colado nele).
          return nil if pts.size < 4
          pts[-1] = pts.first.clone
          refs[-1] = refs.first && refs.first.clone
        end
        return nil if pts.size < 2

        # Trajeto aberto: estende 1 mm em cada ponta, para a luz entrar um
        # pouco atrás da peça vizinha e não deixar fresta no encontro.
        unless closed
          head = pts[1] - pts[0]
          tail = pts[-1] - pts[-2]
          pts[0]  = pts[0] - scaled(head.normalize, 1.mm) unless tiny?(head)
          pts[-1] = pts[-1] + scaled(tail.normalize, 1.mm) unless tiny?(tail)
        end

        ensure_outward_laterals!(pts, refs, closed)

        # Cima/Baixo vale em trajeto aberto e em contorno deitado (tampo,
        # prateleira). Em painel em pé, Z está no próprio plano da face e o
        # lado certo é Fora/Dentro.
        normal = prep[:face_normal]
        vertical_dir = nil
        if %w[up down].include?(vertical_mode.to_s) &&
           (!closed || normal.dot(Z_AXIS).abs >= 0.707)
          vertical_dir = vertical_mode.to_s == 'up' ? Z_AXIS.clone : Z_AXIS.reverse
        end
        refs.map! { |ref| ref && ref.reverse } if direction_in && vertical_dir.nil?

        sides = (0...pts.size - 1).map do |i|
          tangent = pts[i + 1] - pts[i]
          return nil if tiny?(tangent)
          side = segment_side(tangent.normalize, normal, vertical_dir)
          return nil unless side
          if vertical_dir.nil?
            ref = refs[i] || refs[i + 1]
            side.reverse! if ref && side.dot(ref) < 0
          end
          side
        end

        last_seg = sides.size - 1
        push = Array.new(pts.size) do |v|
          before = v > 0 ? sides[v - 1] : (closed ? sides[last_seg] : nil)
          after  = v <= last_seg ? sides[v] : (closed ? sides[0] : nil)
          dir = if before && after
                  mid = before + after
                  tiny?(mid) ? after : mid.normalize
                else
                  before || after
                end
          scaled(dir, width)
        end

        lift = scaled(normal, offset)
        { base: pts.map { |pt| pt + lift }, push: push, closed: closed }
      rescue StandardError => error
        warn("K.Light LED Inteligente: #{error.message}")
        nil
      end

      def self.layer_materials(model, n_layers, params)
        r, g, b = ribbon_layer_rgb(params)
        (0...n_layers).map do |layer|
          mat       = model.materials.add(Core.next_mat_name("KL_#{layer}"))
          mat.color = Sketchup::Color.new(r, g, b)
          mat.alpha = ribbon_layer_alpha(layer, n_layers, params)
          mat
        end
      end

      # Camada k vai de base + push·k/n até base + push·(k+1)/n. Um
      # PolygonMesh por camada, dois triângulos por trecho, frente e verso
      # com o material da camada. Devolve o nº de faces criadas.
      #
      # O retorno de add_faces_from_mesh NÃO serve como contagem: no
      # SketchUp 2024 ele devolve 0 mesmo criando as faces. Contamos as
      # faces do container antes e depois.
      def self.add_layer_meshes(ge, base, push, mats)
        faces_before = ge.count { |e| e.is_a?(Sketchup::Face) }
        n_layers = mats.size
        count    = base.size
        rows = (0..n_layers).map do |k|
          f = k.to_f / n_layers
          base.each_with_index.map { |pt, i| pt + scaled(push[i], f) }
        end

        n_layers.times do |k|
          mesh  = Geom::PolygonMesh.new(count * 2, (count - 1) * 2)
          inner = rows[k].map { |pt| mesh.add_point(pt) }
          outer = rows[k + 1].map { |pt| mesh.add_point(pt) }
          (count - 1).times do |i|
            mesh.add_polygon(inner[i], inner[i + 1], outer[i + 1])
            mesh.add_polygon(inner[i], outer[i + 1], outer[i])
          end
          ge.add_faces_from_mesh(mesh, 0, mats[k], mats[k])
        end
        ge.count { |e| e.is_a?(Sketchup::Face) } - faces_before
      end

      # Esconde/suaviza todas as arestas da fita numa única varredura, depois
      # da malha pronta. Devolve { entityID => aresta }.
      def self.soften_edges(ge)
        edges = {}
        ge.grep(Sketchup::Edge).each do |edge|
          next unless edge.valid?
          edge.hidden = true
          edge.soft   = true
          edge.smooth = true
          edges[edge.entityID] = edge
        end
        edges
      end

      # Renderizador da fita LED. O LED Inteligente (params[:smart_contour])
      # usa contour_frame; os demais modos do painel usam os laterais
      # suavizados do prep. As duas rotas terminam em add_layer_meshes.
      def self.build_ribbon_geo(ge, prep, params, model)
        empty = { created: 0, edges: {}, materials: [] }
        wpts  = prep[:wpts]
        npts  = wpts.size
        return empty if npts < 2

        width_in     = params[:width_cm].to_f.clamp(0.5, 200.0) / 2.54
        offset_in    = params[:offset_mm].to_f.clamp(0.0, 20.0) / 25.4
        n_layers     = params[:layers].to_i.clamp(2, 120)
        direction_in = params[:direction].to_s == 'in'

        if params[:smart_contour]
          frame = contour_frame(prep, width_in, direction_in: direction_in,
                                vertical_mode: params[:vertical].to_s,
                                offset: offset_in)
          return empty unless frame
          base = frame[:base]
          push = frame[:push]
        else
          face_normal = prep[:face_normal]
          laterals = prep[:auto_lats].dup
          case params[:vertical].to_s
          when 'up'
            laterals = vertical_safe_laterals(wpts, Geom::Vector3d.new(0, 0,  1), laterals)
          when 'down'
            laterals = vertical_safe_laterals(wpts, Geom::Vector3d.new(0, 0, -1), laterals)
          end

          # vertical_safe_laterals recalcula a direção projetando Cima/Baixo
          # no plano perpendicular à tangente — isso não sabe nada de
          # dentro/fora do laço. Reancora pra FORA aqui, depois do ajuste
          # vertical e antes do toggle do usuário; senão laços fechados
          # podiam sair pra dentro com "Fora" selecionado.
          closed = npts > 2 && (wpts.first - wpts.last).length.to_f < 1e-4
          ensure_outward_laterals!(wpts, laterals, closed)
          laterals = laterals.map { |lat| lat ? lat.reverse : nil } if direction_in

          if laterals.compact.empty?
            cands = [Geom::Vector3d.new(0, 0, 1), Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 1, 0)]
            fallback = cands.map { |cand| face_normal.cross(cand) }.find { |vec| !tiny?(vec) }
            laterals = Array.new(npts) { fallback ? fallback.normalize : Geom::Vector3d.new(1, 0, 0) }
          end

          estimated = (npts - 1) * n_layers * 2
          if estimated > Core::MAX_FACES
            # No preview, reduz só a resolução temporária para manter a
            # interação viva. Na aplicação final, o chamador recebe -1 e pede
            # ao usuário para simplificar/baixar camadas.
            return { created: -1, edges: {}, materials: [] } unless params[:preview_quality]
            max_layers = [Core::MAX_FACES / ((npts - 1) * 2), 2].max
            n_layers = [n_layers, max_layers].min
          end

          lift = scaled(face_normal, offset_in)
          zero = Geom::Vector3d.new(0, 0, 0)
          base = wpts.map { |pt| pt + lift }
          push = laterals.map { |lat| lat ? scaled(lat, width_in) : zero }
        end

        mats    = layer_materials(model, n_layers, params)
        created = add_layer_meshes(ge, base, push, mats)
        { created: created, edges: soften_edges(ge), materials: mats }
      end

      # Grava os atributos de edição futura no grupo.
      def self.store_ribbon_attrs(group, prep, params)
        wpts = prep[:wpts]
        fn   = prep[:face_normal]
        group.set_attribute(ATTR_DICT,'kind',       'ribbon')
        # IMPORTANTE: p.x/p.y/p.z (e fn.x/fn.y/fn.z) são objetos Length, não
        # Float puro. Length#to_s é sobrescrito pelo SketchUp pra formatar
        # com unidade (ex.: 10", 1'-2"), e é exatamente esse to_s que
        # JSON.generate usa por baixo dos panos pra serializar números —
        # sem o .to_f aqui, o JSON gravado sai com texto/aspas soltas dentro
        # dos colchetes (inválido). Na leitura (Core.numeric_point_list),
        # esse JSON quebrado falha o parse e a edição perde o trajeto salvo
        # (era isso que fazia "Editar Luz Selecionada" não abrir nada pro
        # LED, e cair em "dados do spot inválidos" pro Spot). Convertendo
        # pra Float aqui, JSON.generate usa o Float#to_json normal (número
        # puro), e a leitura volta a funcionar.
        group.set_attribute(ATTR_DICT,'path_pts',   JSON.generate(wpts.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }))
        group.set_attribute(ATTR_DICT,'face_normal',JSON.generate([fn.x.to_f, fn.y.to_f, fn.z.to_f]))
        group.set_attribute(ATTR_DICT,'width_cm',   params[:width_cm].to_f)
        group.set_attribute(ATTR_DICT,'layers',     params[:layers].to_i)
        group.set_attribute(ATTR_DICT,'alpha_max',  params[:alpha_max].to_f)
        group.set_attribute(ATTR_DICT,'curve_exp',  params[:curve_exp].to_f)
        group.set_attribute(ATTR_DICT,'preset',     params[:preset].to_s)
        group.set_attribute(ATTR_DICT,'rgb_custom', JSON.generate(params[:rgb_custom]))
        group.set_attribute(ATTR_DICT,'direction',  params[:direction].to_s == 'in' ? 'in' : 'out')
        group.set_attribute(ATTR_DICT,'vertical',   params[:vertical].to_s)
        group.set_attribute(ATTR_DICT,'offset_mm',  params[:offset_mm].to_f)
        # Só gravado quando true — luzes de outros modos (Aresta, Espelho,
        # Sanca, Face, Letreiro) simplesmente não ganham esse atributo, e
        # continuam lidas como antes (nil/false) em qualquer código que já
        # exista hoje.
        group.set_attribute(ATTR_DICT,'smart_contour', true) if params[:smart_contour]
        group.set_attribute(ATTR_DICT,'version',    PLUGIN_VERSION)
      end

      # group.entityID => {params que afetam a POSIÇÃO dos vértices na última
      # reconstrução}. Usado só pra decidir se dá pra pular a reconstrução de
      # malha no preview ao vivo — não precisa sobreviver entre sessões.
      @ribbon_geo_cache = {}

      def self.ribbon_geo_key(params)
        { width_cm: params[:width_cm].to_f, layers: params[:layers].to_i,
          offset_mm: params[:offset_mm].to_f, direction: params[:direction].to_s,
          vertical: params[:vertical].to_s, optimize: params[:optimize] ? true : false }
      end

      # Reconstrói a geometria de um grupo existente (usado pelo preview).
      # NÃO abre nem fecha operação — chame dentro de uma já aberta.
      #
      # Só largura/camadas/deslocamento/direção/vertical mudam a POSIÇÃO dos
      # vértices — cor, intensidade e queda só mudam o material. Antes,
      # QUALQUER alteração (até só de cor) disparava limpar e reconstruir
      # toda a malha triângulo por triângulo a cada tick de slider — em
      # faixas com muitas camadas/pontos (ex: fita numa curva longa), isso
      # travava visivelmente o preview ao vivo. Agora, se os parâmetros que
      # afetam a posição não mudaram desde a última reconstrução, só
      # retintamos os materiais que já existem, sem tocar na malha.
      #
      # prev_mats: materiais criados na reconstrução anterior desse mesmo
      # grupo. Em vez de "purgar" com uma varredura em TODOS os materiais do
      # modelo a cada tick do preview (pesado em arquivos de projeto grandes
      # com centenas de materiais alheios), removemos direto só os que nós
      # mesmos criamos na rodada passada — já sabemos exatamente quais são.
      # Retorna a nova lista de materiais, pra encadear na próxima chamada.
      def self.rebuild_ribbon(model, group, prep, params, prev_mats = nil, preview: false)
        return prev_mats || [] unless group.valid?

        render_params = preview ? Core.preview_params(params, :ribbon) : params
        geo_key = ribbon_geo_key(render_params)
        if prev_mats && !prev_mats.empty? && @ribbon_geo_cache[group.entityID] == geo_key
          retint_ribbon_materials(prev_mats, render_params)
          model.active_view.invalidate
          return prev_mats
        end

        group.entities.clear!
        if prev_mats && !prev_mats.empty?
          prev_mats.each { |m| model.materials.remove(m) rescue nil }
        end
        result = build_ribbon_geo(group.entities, prep, render_params, model)
        @ribbon_geo_cache[group.entityID] = geo_key
        model.active_view.invalidate
        result[:materials] || []
      end

      # -----------------------------------------------------------------------
      def self.create_ribbon(model, edges, params)
        prep = ribbon_prep(model, edges, force_optimize: params[:optimize])
        unless prep
          UI.messagebox("K.Light: caminho inválido — verifique se as arestas se tocam.")
          return nil
        end
        group = build_and_store_ribbon(model, prep, params, op_name: 'K.Light — Criar LED')
        replace_edges_with_curve(edges, prep[:path_pts]) if group && params[:optimize]
        group
      end

      # Corpo compartilhado de criação de UM grupo de fita a partir de um
      # `prep` já pronto (venha ele de arestas ou de um loop de face). Isso
      # deixa o modo clássico (arestas) e o modo "Letreiro" (faces) usarem
      # exatamente o mesmo caminho de criação, sem duplicar lógica.
      #
      # open_op: quando false, assume que o chamador já abriu (e vai
      # fechar) a operação — usado pelo modo Letreiro pra criar várias
      # fitas de uma vez como um único passo de undo.
      def self.build_and_store_ribbon(model, prep, params, op_name:, open_op: true,
                                      active_context: false)
        npts = prep[:wpts].size
        est  = (npts - 1) * params[:layers].to_i * 2
        if est > Core::MAX_FACES
          UI.messagebox("K.Light: essa combinação geraria ~#{est} faces (limite #{Core::MAX_FACES}).\n" \
                        "Reduza camadas ou segmentos.")
          return nil
        end

        model.start_operation(op_name, true) if open_op
        begin
          container   = active_context ? model.active_entities : model.entities
          group       = container.add_group
          # O prep do LED Inteligente está em coordenadas globais. Quando o
          # grupo nasce dentro do contexto aberto, a transformação inversa
          # neutraliza a transformação do pai: a geometria continua no mesmo
          # lugar no mundo e permanece visível enquanto o bloco está aberto.
          if active_context && model.respond_to?(:edit_transform) &&
             model.active_entities != model.entities
            group.transformation = model.edit_transform.inverse
          end
          group.name  = "K.Light_#{params[:preset]}"
          group.layer = Core.ensure_tag(model)

          result = build_ribbon_geo(group.entities, prep, params, model)

          if result[:created] == 0 || !group.valid?
            # Com operação própria, o abort_operation já desfaz o grupo —
            # apagar antes disso remove o grupo duas vezes (BugSplat).
            group.erase! if group.valid? && !open_op
            model.abort_operation if open_op
            UI.messagebox("K.Light: a curva gerou uma malha inválida.")
            return nil
          end

          store_ribbon_attrs(group, prep, params)
          model.commit_operation if open_op
          group

        rescue => err
          model.abort_operation if open_op
          UI.messagebox("K.Light erro:\n#{err.message}\n\n#{err.backtrace.first(4).join("\n")}")
          nil
        end
      end

    # LED — abre o diálogo já na aba LED com preview ao vivo
    def self.cmd_create_led
      model = Sketchup.active_model

      # MODO LETREIRO: se a seleção tiver alguma face (ex.: letras 3D
      # extrudadas selecionadas pela face frontal), usa o caminho por
      # loop de face em vez do caminho por arestas soltas — mais robusto
      # pra texto/logo porque não depende de "adivinhar" conectividade.
      faces = model.selection.grep(Sketchup::Face)
      return cmd_create_led_letreiro(model, faces) unless faces.empty?

      edges = KLight.collect_selection_edges(model.selection)
      if edges.empty?
        UI.messagebox("K.Light: selecione as arestas (ou as faces das letras, " \
                      "pro modo letreiro) primeiro.\n\n" \
                      "Se estiverem dentro de um grupo, entre nele com duplo clique.")
        return
      end

      # Ponto bruto do trajeto (sem otimizar ainda) — só pra decidir se a
      # curva é "complexa" o bastante pra ligar Otimizar Linhas sozinha.
      raw_pts       = edges_to_path(edges)
      auto_optimize = raw_pts.size > AUTO_SIMPLIFY_MIN_POINTS

      prep = ribbon_prep(model, edges, force_optimize: auto_optimize)
      unless prep
        UI.messagebox("K.Light: caminho inválido — verifique se as arestas se tocam.")
        return
      end

      preview_group = nil
      prev_mats     = nil
      default_p = { width_cm: 12, layers: 32, alpha_max: 0.85, curve_exp: 2.2,
                    offset_mm: 0.5, preset: 'quente', rgb_custom: nil,
                    direction: 'out', vertical: 'down', optimize: auto_optimize }

      # Recalcula o trajeto (com ou sem otimização, conforme o botão do
      # painel) sempre que o preview/aplicar rodar — ao contrário dos outros
      # parâmetros (cor, largura...), "Otimizar Linhas" muda os PONTOS do
      # trajeto, não só a aparência, então precisa refazer o ribbon_prep, não
      # só retintar.
      refresh_prep = lambda do |p|
        new_prep = ribbon_prep(model, edges, force_optimize: p[:optimize])
        prep = new_prep if new_prep
      end

      Dialog.show(
        # CRIAR — finaliza o grupo com os params escolhidos, sempre com o
        # nº de camadas EXATO que o usuário configurou (nunca o reduzido
        # usado durante o arraste do slider)
        ->(p) {
          if preview_group&.valid?
            refresh_prep.call(p)
            prev_mats = rebuild_ribbon(model, preview_group, prep, p, prev_mats)
            preview_group.name = "K.Light_#{p[:preset]}"
            store_ribbon_attrs(preview_group, prep, p)
            replace_edges_with_curve(edges, prep[:path_pts]) if p[:optimize]
            model.commit_operation
            model.selection.clear
            model.selection.add(preview_group)
          else
            # on_ready não chegou a rodar (raro) — cria normalmente
            create_ribbon(model, edges, p)
          end
        },
        # CANCELAR
        -> { model.abort_operation if preview_group },
        nil,
        # PREVIEW — reconstrói dentro da operação aberta
        ->(p) {
          next unless preview_group&.valid?
          refresh_prep.call(p)
          prev_mats = rebuild_ribbon(model, preview_group, prep, p, prev_mats, preview: true)
        },
        init: { tab: 'faixa', optimize: auto_optimize },
        # ON_READY — o diálogo já está na tela: agora é seguro abrir a operação
        on_ready: -> {
          begin
            model.start_operation('K.Light — Criar LED', true)
            preview_group = model.entities.add_group
            preview_group.layer = Core.ensure_tag(model)
            result = build_ribbon_geo(preview_group.entities, prep, Core.preview_params(default_p, :ribbon), model)
            prev_mats = result[:materials] || []
            model.active_view.invalidate
          rescue => err
            model.abort_operation rescue nil
            UI.messagebox("K.Light: erro ao iniciar preview.\n#{err.message}")
          end
        }
      )
    end

    # LED — MODO LETREIRO: uma face selecionada (ou várias, várias letras
    # de uma vez) -> um prep por contorno (Face#loops: externo + furos) ->
    # uma fita por contorno, todas com preview ao vivo simultâneo. Ao
    # confirmar, todas as fitas são criadas juntas como um único passo de
    # undo, cada uma como um grupo K.Light independente e editável depois
    # pelo "✏ Editar Luz Selecionada" normalmente.
    def self.cmd_create_led_letreiro(model, faces)
      preps = faces_to_preps(model, faces)
      if preps.empty?
        UI.messagebox("K.Light: não encontrei contornos válidos nas faces selecionadas.")
        return
      end

      preview_groups = nil
      prev_mats_list = nil
      default_p = { width_cm: 12, layers: 32, alpha_max: 0.85, curve_exp: 2.2,
                    offset_mm: 0.5, preset: 'quente', rgb_custom: nil,
                    direction: 'out', vertical: 'down' }

      rebuild_all = lambda do |p|
        preview_groups.each_with_index do |g, idx|
          prev_mats_list[idx] = rebuild_ribbon(model, g, preps[idx], p, prev_mats_list[idx], preview: true)
        end
      end

      Dialog.show(
        # CRIAR
        ->(p) {
          if preview_groups && !preview_groups.empty?
            rebuild_all.call(p)
            preview_groups.each_with_index do |g, idx|
              g.name = "K.Light_#{p[:preset]}_#{idx + 1}"
              store_ribbon_attrs(g, preps[idx], p)
            end
            model.commit_operation
            model.selection.clear
            preview_groups.each { |g| model.selection.add(g) }
          end
        },
        # CANCELAR
        -> { model.abort_operation if preview_groups },
        nil,
        # PREVIEW
        ->(p) {
          next unless preview_groups && !preview_groups.empty?
          rebuild_all.call(p)
        },
        init: { tab: 'faixa' },
        on_ready: -> {
          begin
            model.start_operation('K.Light — Criar LED (letreiro)', true)
            preview_groups = preps.map do
              g = model.entities.add_group
              g.layer = Core.ensure_tag(model)
              g
            end
            prev_mats_list = preps.each_with_index.map do |prep, idx|
              result = build_ribbon_geo(preview_groups[idx].entities, prep, Core.preview_params(default_p, :ribbon), model)
              result[:materials] || []
            end
            model.active_view.invalidate
          rescue => err
            model.abort_operation rescue nil
            UI.messagebox("K.Light: erro ao iniciar preview do letreiro.\n#{err.message}")
          end
        }
      )
    end

    # LED INTELIGENTE: basta selecionar uma aresta de uma face plana fechada.
    # O loop daquela face é reconhecido automaticamente; o painel mantém os
    # controles usuais de largura, intensidade, Fora/Dentro e Cima/Baixo.
    def self.open_smart_led_dialog(model, prep = nil)
      model = Sketchup.active_model
      if prep.nil?
      edges = KLight.collect_selection_edges(model.selection)

      if edges.size != 1
        UI.messagebox("K.Light: selecione somente uma aresta do contorno que deseja iluminar.\n\n" +                      "A aresta precisa pertencer a uma face plana fechada.")
        return
      end

      prep = smart_loop_prep_from_edge(model, edges.first)
      unless prep
        UI.messagebox("K.Light: não encontrei um contorno fechado nessa aresta.\n\n" +                      "Selecione uma aresta que faça parte da face do espelho, nicho ou painel.")
        return
      end

      end
      preview_group = nil
      prev_mats = nil
      default_p = { width_cm: 12, layers: 32, alpha_max: 0.85, curve_exp: 2.2,
                    offset_mm: 0.5, preset: 'quente', rgb_custom: nil,
                    direction: 'out', vertical: 'down' }

      # Só este fluxo (LED Inteligente por Contorno) usa o gerador de
      # contorno (contour_frame) em build_ribbon_geo. `p` vem de um
      # round-trip por JSON com o HTML do painel (Dialog.show faz
      # JSON.parse do que o JS devolve) — um campo que só existe do lado
      # Ruby, como este, NÃO sobrevive a esse round-trip, então precisa ser
      # remesclado aqui a cada callback em vez de só uma vez em default_p.
      with_flag = ->(p) { p.merge(smart_contour: true) }

      Dialog.show(
        ->(p) {
          p = with_flag.call(p)
          if preview_group&.valid?
            prev_mats = rebuild_ribbon(model, preview_group, prep, p, prev_mats)
            preview_group.name = "K.Light_Inteligente_#{p[:preset]}"
            store_ribbon_attrs(preview_group, prep, p)
            model.commit_operation
            model.selection.clear
            model.selection.add(preview_group)
          end
        },
        -> { model.abort_operation if preview_group },
        nil,
        ->(p) {
          next unless preview_group&.valid?
          prev_mats = rebuild_ribbon(model, preview_group, prep, with_flag.call(p), prev_mats, preview: true)
        },
        init: { tab: 'faixa' },
        on_ready: -> {
          begin
            model.start_operation('K.Light — LED Inteligente', true)
            preview_group = model.entities.add_group
            preview_group.layer = Core.ensure_tag(model)
            result = build_ribbon_geo(
              preview_group.entities,
              prep,
              Core.preview_params(with_flag.call(default_p), :ribbon),
              model
            )
            prev_mats = result[:materials] || []
            model.active_view.invalidate
          rescue => err
            model.abort_operation rescue nil
            UI.messagebox("K.Light: erro ao iniciar LED Inteligente.\n#{err.message}")
          end
        }
      )
    end

    # Criação imediata do LED Inteligente. A largura lateral automática evita
    # a quebra nos trechos verticais que ocorria quando o modo Baixo era
    # aplicado como padrão a um contorno fechado.
    def self.create_smart_led_now(model, prep)
      params = {
        width_cm: 12,
        layers: 24,
        alpha_max: 0.85,
        curve_exp: 2.2,
        offset_mm: 0.5,
        preset: 'quente',
        rgb_custom: nil,
        direction: 'out',
        vertical: 'down',
        # Único ponto de criação instantânea do LED Inteligente por
        # Contorno — liga o gerador de contorno só aqui.
        smart_contour: true
      }
      group = build_and_store_ribbon(
        model,
        prep,
        params,
        op_name: 'K.Light — LED Inteligente',
        active_context: true
      )
      return unless group

      group.name = 'K.Light_Inteligente_quente'
      model.selection.clear
      model.selection.add(group)
      model.active_view.invalidate
    end

    # Ferramenta interativa: encontra a aresta sob o cursor mesmo dentro de
    # grupos/componentes e mostra uma faixa temporária antes do clique.
    class SmartLedTool
      def activate
        @prep = nil
        clear_preview
        Sketchup.status_text = 'LED Inteligente: passe o mouse sobre uma aresta, curva ou contorno e clique para criar'
      end

      # A prévia é calculada só quando o mouse se move (o alvo pode ter
      # mudado). draw() roda a cada repaint, dezenas de vezes por segundo,
      # então ali só desenhamos o que já está pronto.
      def onMouseMove(_flags, x, y, view)
        @prep = pick_prep(x, y, view)
        rebuild_preview
        view.invalidate
      end

      def onLButtonUp(_flags, _x, _y, _view)
        return unless @prep
        model = Sketchup.active_model
        model.select_tool(nil)
        Led.create_smart_led_now(model, @prep)
      end

      def draw(view)
        return unless @preview_pts && @preview_pts.size >= 2

        # Verde de destaque da prévia: #CAC307.
        view.drawing_color = Sketchup::Color.new(202, 195, 7, 72)
        view.draw(GL_TRIANGLES, @preview_tris) unless @preview_tris.empty?

        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(202, 195, 7)
        view.draw(GL_LINE_STRIP, @preview_pts)
        view.draw(GL_LINES, @preview_rim) unless @preview_rim.empty?
      end

      private

      def clear_preview
        @preview_pts  = nil
        @preview_tris = []
        @preview_rim  = []
      end

      # Prévia fina (8 cm), com a mesma geometria de borda da fita real
      # (Led.contour_frame), pra mostrar fielmente onde a faixa vai nascer.
      def rebuild_preview
        frame = @prep && Led.contour_frame(@prep, 8.cm, vertical_mode: 'down')
        return clear_preview unless frame

        base = frame[:base]
        rim  = base.each_with_index.map { |pt, i| pt + frame[:push][i] }
        tris = []
        rim_lines = []
        (base.size - 1).times do |i|
          tris.push(base[i], base[i + 1], rim[i + 1], base[i], rim[i + 1], rim[i])
          rim_lines.push(rim[i], rim[i + 1])
        end

        @preview_pts  = base
        @preview_tris = tris
        @preview_rim  = rim_lines
      end

      def pick_prep(x, y, view)
        picker = view.pick_helper
        picker.do_pick(x, y)

        (0...picker.count).each do |index|
          path = picker.path_at(index) rescue []
          edge = path.reverse.find { |entity| entity.is_a?(Sketchup::Edge) }
          next unless edge && edge.valid?

          transform = if picker.respond_to?(:transformation_at)
                        picker.transformation_at(index)
                      else
                        edge_index = path.rindex(edge)
                        value = Geom::Transformation.new
                        path[0...edge_index].each do |entity|
                          value = value * entity.transformation if entity.respond_to?(:transformation)
                        end
                        value
                      end

          prep = prep_for_edge(edge, transform)
          return prep if prep
        end

        # InputPoint captura bem uma reta fina isolada, que o PickHelper
        # às vezes deixa escapar.
        input = Sketchup::InputPoint.new
        input.pick(view, x, y)
        edge = input.edge
        if edge && edge.valid?
          transform = input.respond_to?(:transformation) ? input.transformation : Geom::Transformation.new
          prep = prep_for_edge(edge, transform)
          return prep if prep
        end
        nil
      end

      def prep_for_edge(edge, transform)
        prep = Led.smart_loop_prep_from_edge(
          Sketchup.active_model, edge, xform_override: transform
        )
        prep ||= Led.wire_prep_from_edge(
          Sketchup.active_model, edge, xform_override: transform
        )
        prep
      end
    end

    def self.cmd_create_smart_led
      model = Sketchup.active_model
      model.selection.clear
      model.select_tool(SmartLedTool.new)
    end

    end # Led
  end
end
