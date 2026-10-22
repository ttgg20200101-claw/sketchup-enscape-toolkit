# encoding: UTF-8
# 索引目录、快照目录、资产库（入库 / 投放）。
# 索引目录结构：
#   assets.json        扫描器写
#   library.json       插件写（入库记录）
#   library\           入库的组件 .skp + 缩略图
#   snapshots\<模型>\<时间>\  锁定快照（state.json / meta.json / textures\）
require 'json'
require 'digest'
require 'fileutils'
require 'erb'

module GZAsset
  module Library
    PREF = 'GZAsset'.freeze

    module_function

    def index_dir
      d = Sketchup.read_default(PREF, 'index_dir', '').to_s
      d.empty? || !File.directory?(d) ? nil : d
    end

    def index_dir=(d)
      Sketchup.write_default(PREF, 'index_dir', d)
    end

    def load_json(path, default)
      return default unless File.file?(path)
      JSON.parse(File.read(path, mode: 'r:BOM|UTF-8'), allow_nan: true)
    rescue JSON::ParserError
      default
    end

    def write_json(path, obj)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(obj, allow_nan: true), mode: 'w:UTF-8')
      File.rename(tmp, path)
    end

    # ---------------- 快照 ----------------

    # 目录名只用 ASCII，避免中文路径在 Windows 上出问题
    def snapshot_root(idx, model)
      title = model.title.to_s
      title = 'untitled' if title.empty?
      File.join(idx, 'snapshots', Digest::MD5.hexdigest(title)[0, 10])
    end

    def write_meta(dir, state)
      write_json(File.join(dir, 'meta.json'),
                 { 'label' => state['label'], 'created_at' => state['created_at'],
                   'model_title' => state['model_title'],
                   'materials' => state['materials'].size })
    end

    def list_snapshots(idx, model)
      root = snapshot_root(idx, model)
      Dir.glob(File.join(root, '*', 'meta.json')).sort.reverse.map do |f|
        load_json(f, {}).merge('dir' => File.dirname(f))
      end
    end

    # ---------------- 入库 ----------------

    def harvest(model, idx, defs, name, tags)
      lib = File.join(idx, 'library')
      FileUtils.mkdir_p(lib)
      path = File.join(idx, 'library.json')
      entries = load_json(path, [])
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      added = []
      defs.each_with_index do |d, i|
        id = format('%s_%02d', stamp, i)
        skp = File.join(lib, "#{id}.skp")
        png = File.join(lib, "#{id}.png")
        raise "保存失败：#{d.name}" unless d.save_as(skp)
        thumb = begin
          d.refresh_thumbnail
          d.save_thumbnail(png) && File.exist?(png)
        rescue StandardError
          false
        end
        e = {
          'id' => id,
          'name' => defs.size == 1 && !name.empty? ? name : d.name,
          'tags' => tags,
          'file' => "library/#{id}.skp",
          'thumb' => thumb ? "library/#{id}.png" : nil,
          'source_model' => model.title.to_s,
          'source_path' => model.path.to_s,
          'harvested_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
        }
        entries << e
        added << e
      end
      write_json(path, entries)
      added
    end

    # ---------------- 投放 ----------------

    def place(model, path)
      d = model.definitions.load(path)
      model.place_component(d)
      d
    end

    def browser_items(idx)
      items = []
      load_json(File.join(idx, 'library.json'), []).each do |e|
        items << {
          'source' => '资产库',
          'name' => e['name'].to_s,
          'tags' => (e['tags'] || []).join(' '),
          'path' => File.join(idx, e['file']),
          'thumb' => e['thumb'] ? file_url(File.join(idx, e['thumb'])) : nil,
          'info' => "来自 #{e['source_model']} · #{e['harvested_at']}"
        }
      end
      assets = load_json(File.join(idx, 'assets.json'), {})
      (assets['files'] || []).each do |f|
        next if f['error']
        s = f['stats'] || {}
        info = format('%.1f MB · 材质 %d · 外链贴图 %d',
                      f['size'].to_f / 1_048_576, s['materials'].to_i, s['external'].to_i)
        info += " · 断链 #{s['missing']}" unless s['missing'].nil?
        items << {
          'source' => '扫描',
          'name' => f['name'].to_s,
          'tags' => (f['vendors'] || []).join(' '),
          'path' => f['path'],
          'thumb' => nil,
          'info' => info
        }
      end
      items
    end

    def file_url(path)
      parts = path.tr('\\', '/').split('/')
      enc = parts.each_with_index.map do |p, i|
        i.zero? && p =~ /\A[A-Za-z]:\z/ ? p : ERB::Util.url_encode(p)
      end
      url = enc.join('/')
      url.start_with?('/') ? "file://#{url}" : "file:///#{url}"
    end
  end
end
