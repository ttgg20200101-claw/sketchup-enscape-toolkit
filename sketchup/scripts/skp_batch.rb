# 只读批量统计 + 规范检查。适配 SketchUp 2022 (Ruby 2.7)。
# 用法（Ruby 控制台）:
#   load File.join(Dir.home, 'Desktop', 'skp_batch.rb')
#   SkpBatch.run('D:/项目/模型', 3)   # 先试 3 个；去掉 3 = 全量
#   SkpBatch.stop                          # 中途停止，再次 run 会跳过已完成的
# 输出: 桌面/skp_batch/ 下每个模型一份 JSON + summary.csv。模型一律不保存（close 时丢弃改动）。
require 'json'
require 'csv'
require 'digest'

module SkpBatch
  OUT = File.join(Dir.home, 'Desktop', 'skp_batch')
  GENERIC_DEF = /\A(Component|组件|Group|_Defintion|\*U)[\d#]*\z/
  GENERIC_MAT = /\A(<auto>\d*|材料\d*|Material ?#?[\d_]*\S*|Material__\S*)\z/
  CSV_HEAD = %w[file size_mb open_sec status defs instances groups materials tags
                unused_defs generic_defs generic_mats whitespace_names dup_material_names]

  def self.run(dir, limit = nil)
    Dir.mkdir(OUT) unless Dir.exist?(OUT)
    root  = dir.tr('\\', '/')
    files = Dir.glob('**/*.skp', base: root).sort.map { |f| File.join(root, f) }.select { |f| File.file?(f) }
    pending = files.reject { |f| File.exist?(json_path(f)) }
    todo  = limit ? pending.first(limit) : pending
    puts "共 #{files.size} 个 .skp，已完成 #{files.size - pending.size}，本次处理 #{todo.size}"
    @queue = todo
    @total = todo.size
    @stop  = false
    step
  end

  def self.stop
    @stop = true
    puts '将在当前文件处理完后停止'
  end

  def self.step
    if @stop || @queue.empty?
      puts "结束。结果在 #{OUT}"
      return
    end
    file = @queue.shift
    idx  = @total - @queue.size
    t0   = Time.now
    begin
      ver = file_version(file)
      if ver && ver > Sketchup.version.to_i
        append_csv(file, 0, "too_new(v#{ver})", nil)
        puts "[#{idx}/#{@total}] 跳过：v#{ver} 版本过新  #{file}"
      else
        Sketchup.active_model.close(true) # 丢弃当前模型改动，避免"是否保存"弹窗
        st  = Sketchup.open_file(file, with_status: true)
        sec = (Time.now - t0).round(1)
        if [Sketchup::Model::LOAD_STATUS_SUCCESS, Sketchup::Model::LOAD_STATUS_SUCCESS_MORE_RECENT].include?(st)
          rep = analyze(Sketchup.active_model, file)
          File.write(json_path(file), JSON.pretty_generate(rep))
          append_csv(file, sec, 'ok', rep)
          puts "[#{idx}/#{@total}] OK #{sec}s  #{file}"
        else
          append_csv(file, sec, "open_failed(v#{ver.inspect},status #{st.inspect})", nil)
          puts "[#{idx}/#{@total}] 打开失败 v#{ver.inspect} status #{st.inspect}  #{file}"
        end
        Sketchup.active_model.close(true)
      end
    rescue StandardError => e
      append_csv(file, (Time.now - t0).round(1), "error: #{e.message}", nil)
      puts "[#{idx}/#{@total}] 出错 #{e.message}  #{file}"
    end
    UI.start_timer(0.5, false) { step }
  end

  def self.analyze(model, file)
    defs  = model.definitions.reject { |d| d.group? || d.image? }
    mats  = model.materials.map(&:display_name)
    tags  = model.layers.map(&:name)
    names = defs.map(&:name) + mats + tags
    {
      'model'      => file,
      'sketchup'   => Sketchup.version,
      'generated'  => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
      'components' => defs.map { |d| { 'name' => d.name, 'instances' => d.count_used_instances } }
                          .sort_by { |h| -h['instances'] },
      'groups'     => model.definitions.count(&:group?),
      'materials'  => mats.sort,
      'tags'       => tags,
      'lint'       => {
        'unused_defs'        => defs.select { |d| d.count_used_instances.zero? }.map(&:name),
        'generic_defs'       => defs.map(&:name).grep(GENERIC_DEF).size,
        'generic_mats'       => mats.grep(GENERIC_MAT).size,
        'whitespace_names'   => names.select { |n| n != n.strip || n.include?('  ') },
        'dup_material_names' => mats.group_by(&:itself).select { |_, v| v.size > 1 }.keys
      }
    }
  end

  def self.append_csv(file, sec, status, rep)
    path  = File.join(OUT, 'summary.csv')
    fresh = !File.exist?(path)
    File.open(path, 'a:UTF-8') do |f|
      f.write("\uFEFF" + CSV_HEAD.to_csv) if fresh
      row = [file, (File.size(file) / 1048576.0).round(1), sec, status]
      if rep
        l = rep['lint']
        row += [rep['components'].size, rep['components'].sum { |c| c['instances'] }, rep['groups'],
                rep['materials'].size, rep['tags'].size, l['unused_defs'].size, l['generic_defs'],
                l['generic_mats'], l['whitespace_names'].size, l['dup_material_names'].size]
      end
      f.write(row.to_csv)
    end
  end

  # .skp 文件头: UTF-16LE "SketchUp Model" 后跟 "{20.0.363}"，取主版本号
  def self.file_version(file)
    head = File.binread(file, 128).delete("\x00")
    m = head.match(/\{(\d+)\.\d+\.\d+\}/n)
    m && m[1].to_i
  end

  def self.json_path(file)
    File.join(OUT, "#{File.basename(file, '.skp')}_#{Digest::MD5.hexdigest(file)[0, 8]}.json")
  end
end
