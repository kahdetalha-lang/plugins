module KahDetalha
  module OrganicCurveTool

    # -- Utilidades geométricas -------------------------------------------

    # Distância perpendicular de um ponto a uma reta (para Douglas-Peucker)
    def self.perp_distance(point, line_start, line_end)
      if line_start == line_end
        return point.distance(line_start)
      end
      v = line_end - line_start
      w = point - line_start
      len2 = v.length ** 2
      t = (v % w) / len2
      t = [[t, 0.0].max, 1.0].min
      proj = line_start.offset(v, t * v.length)
      point.distance(proj)
    end

    # Douglas-Peucker ITERATIVO (pilha explícita, sem recursão Ruby) — ver
    # a mesma versão/explicação em 01_k_light_l/led.rb#douglas_peucker.
    # Evita estourar a pilha de chamadas do Ruby embutido no SketchUp em
    # curvas muito compridas/quase retas.
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

    # Resample Catmull-Rom para suavizar antes (ou em vez) de simplificar
    def self.catmull_rom_resample(points, segments_per_span, closed = false)
      return points if points.length < 3

      pts = points.dup
      pts = [pts[0]] + pts + [pts[-1]] unless closed
      pts = [pts[-2]] + pts + [pts[1]] if closed

      result = []
      (1..(pts.length - 3)).each do |i|
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        segments_per_span.times do |s|
          t = s.to_f / segments_per_span
          t2 = t * t
          t3 = t2 * t
          x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t +
                     (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                     (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
          y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t +
                     (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                     (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
          z = 0.5 * ((2 * p1.z) + (-p0.z + p2.z) * t +
                     (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2 +
                     (-p0.z + 3 * p1.z - 3 * p2.z + p3.z) * t3)
          result << Geom::Point3d.new(x, y, z)
        end
      end
      result << points.last unless closed
      result
    end

    # -- Extração da cadeia de edges ---------------------------------------

    # Recebe um array de Sketchup::Edge selecionados e devolve
    # { :points => [...], :closed => bool } ou levanta RuntimeError
    def self.extract_chain(edges)
      raise "Selecione ao menos 2 edges conectados." if edges.length < 2

      vertex_edges = Hash.new { |h, k| h[k] = [] }
      edges.each do |e|
        vertex_edges[e.start] << e
        vertex_edges[e.end] << e
      end

      branch = vertex_edges.values.find { |es| es.length > 2 }
      if branch
        raise "A seleção tem uma ramificação (um ponto conectado a #{branch.length} edges). " \
              "Selecione apenas um caminho simples ou um loop fechado."
      end

      endpoints = vertex_edges.select { |_, es| es.length == 1 }.keys
      closed = endpoints.empty?

      start_vertex = closed ? edges.first.start : endpoints.first

      ordered_points = [start_vertex.position]
      visited_edges = {}
      current_vertex = start_vertex

      loop do
        next_edge = vertex_edges[current_vertex].find { |e| !visited_edges[e] }
        break unless next_edge

        visited_edges[next_edge] = true
        next_vertex = (next_edge.start == current_vertex) ? next_edge.end : next_edge.start
        ordered_points << next_vertex.position
        current_vertex = next_vertex

        break if closed && current_vertex == start_vertex
      end

      unless visited_edges.length == edges.length
        raise "Não foi possível montar uma cadeia única e contínua com os edges selecionados."
      end

      { :points => ordered_points, :closed => closed }
    end

    # -- Ação principal ------------------------------------------------------

    def self.run
      model = Sketchup.active_model
      sel = model.selection
      edges = sel.grep(Sketchup::Edge)

      if edges.empty?
        UI.messagebox("Selecione a forma orgânica (edges) antes de rodar o comando.")
        return
      end

      # Mesmo limite de segurança do K.Light (Core::MAX_EDGES): uma seleção
      # gigante faria extract_chain/douglas_peucker gastar memória e tempo
      # à toa numa única operação. Aplicável só quando carregado dentro do
      # K.Light (onde Core existe) — rodando como plugin standalone, sem
      # esse módulo, o limite simplesmente não se aplica.
      max_edges = defined?(KahDetalha::KLight::Core::MAX_EDGES) ? KahDetalha::KLight::Core::MAX_EDGES : nil
      if max_edges && edges.length > max_edges
        UI.messagebox("Limpeza de Linhas: a seleção tem #{edges.length} arestas, " \
                      "acima do limite seguro de #{max_edges}.\n\nSelecione um trecho menor por vez.")
        return
      end

      begin
        chain = extract_chain(edges)
      rescue => e
        UI.messagebox("Erro: #{e.message}")
        return
      end

      tolerance = 0.05
      smooth = false
      seg_per_span = 6

      points = chain[:points]
      points = catmull_rom_resample(points, seg_per_span, chain[:closed]) if smooth
      points = douglas_peucker(points, tolerance) if tolerance > 0

      if points.length < 3
        UI.messagebox("Resultado ficou com poucos pontos. Reduza a tolerância e tente de novo.")
        return
      end

      model.start_operation("Linha contínua orgânica", true)
      entities = edges.first.parent.entities
      edges.each { |e| e.erase! if e.valid? }
      entities.add_curve(points)
      model.commit_operation

      UI.messagebox("Pronto: #{edges.length} segmentos -> #{points.length - 1} segmentos, agora como uma única curva.")
    end

    # Sem registro de menu próprio aqui — esta ferramenta agora vive dentro
    # do K.Light (menu "🧹 Limpeza de Linhas" e botão da toolbar), registrado
    # em 01_k_light_l.rb. Mantido como módulo standalone só pelo código
    # (self.run), sem duplicar entrada no menu "Plugins".

  end
end
