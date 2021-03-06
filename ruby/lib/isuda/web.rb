require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'

require 'redis'
require 'hiredis'

module Isuda
  class Web < ::Sinatra::Base
    enable :protection
    enable :sessions

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, ENV['ISUDA_DB_USER'] || 'root'
    set :db_password, ENV['ISUDA_DB_PASSWORD'] || ''
    set :dsn, ENV['ISUDA_DSN'] || 'dbi:mysql:db=isuda'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :isutar_origin, ENV['ISUTAR_ORIGIN'] || 'http://localhost:5001'

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = user_by_id(user_id)
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      def db
        Thread.current[:db] ||=
          begin
            _, _, attrs_part = settings.dsn.split(':', 3)
            attrs = Hash[attrs_part.split(';').map {|part| part.split('=', 2) }]
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: attrs['db'],
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def redis
        Thread.current[:redis] ||=
          Redis.new(:host => "127.0.0.1", :port => 6379, driver: :hiredis)
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        return false if ENV['RACK_ENV'] == 'development'

        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def regexp_keywords
        @regexp_keywords ||= db.xquery('select keyword from entry order by character_length(keyword) desc').map {|k| Regexp.escape(k[:keyword]) }
      end

      def htmlify(content)
        pattern = regexp_keywords.join('|')
        kw2hash = {}
        hashed_content = content.gsub(/(#{pattern})/) {|m|
          matched_keyword = $1
          "isuda_#{Digest::SHA1.hexdigest(matched_keyword)}".tap do |hash|
            kw2hash[matched_keyword] = hash
          end
        }
        escaped_content = Rack::Utils.escape_html(hashed_content)
        kw2hash.each do |(keyword, hash)|
          keyword_url = url("/keyword/#{Rack::Utils.escape_path(keyword)}")
          anchor = '<a href="%s">%s</a>' % [keyword_url, Rack::Utils.escape_html(keyword)]
          escaped_content.gsub!(hash, anchor)
        end
        escaped_content.gsub(/\n/, "<br />\n")
      end

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      def load_stars(keyword)
        redis.lrange(redis_key_for_star(keyword), 0, -1).map do |user_name|
          { 'user_name' => user_name }
        end
      end

      def redis_key_for_star(keyword)
        "star_#{Digest::SHA1.hexdigest(keyword)}"
      end

      def redis_key_for_html(keyword)
        "html_#{Digest::SHA1.hexdigest(keyword)}"
      end

      def redirect_found(path)
        redirect(path, 302)
      end

      def users
        @users ||= db.query('select id, name, salt, password from user order by id').to_a
      end

      def user_by_name(name)
        @user_by_name ||= users.map do |user|
          [user[:name], user]
        end.to_h

        @user_by_name[name]
      end

      def user_by_id(id)
        users[id - 1]
      end

      def html_by_keyword(keyword, description = nil)
        key = redis_key_for_html(keyword)
        cache = redis.get(key)
        return cache if cache

        description ||= db.xquery(%| select description from entry where keyword = ? LIMIT 1 |, keyword).first[:description]
        html = htmlify(description)
        redis.set(key, html)
        html
      end

      def remove_html_cache(keywords)
        keywords.each do |keyword|
          redis.del(redis_key_for_html(keyword))
        end
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      redis.flushall

      db.query('select keyword, html from entry').each do |entry|
        key = redis_key_for_html(entry[:keyword])
        redis.set(key, entry[:html])
      end

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      entries = db.xquery(%|
        SELECT keyword FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)
      entries.each do |entry|
        entry[:html] = html_by_keyword(entry[:keyword])
        entry[:stars] = load_stars(entry[:keyword])
      end

      total_entries = db.xquery(%| SELECT count(*) AS total_entries FROM entry |).first[:total_entries].to_i

      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]

      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = user_by_name(name)
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      begin
        db.prepare(%|
          insert into entry (
            author_id,
            keyword,
            description,
            created_at,
            updated_at
          )
          values (?, ?, ?, NOW(), NOW())
        |).execute(@user_id, keyword, description)
        keywords = db.prepare("select keyword from entry where description like ?").execute("%#{keyword}%").map do |entry|
          entry[:keyword]
        end
        regexp_keywords.push(Regexp.escape(keyword))
      rescue Mysql2::Error => err
        raise err unless err.to_s.include? 'Duplicate entry'
        db.prepare(%|
          update entry set
            author_id = ?,
            description = ?,
            updated_at = NOW()
          where keyword = ?
        |).execute(@user_id, description, keyword)
        keywords = [keyword]
      end

      remove_html_cache(keywords)

      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select keyword from entry where keyword = ? LIMIT 1 |, keyword).first or halt(404)
      entry[:stars] = load_stars(entry[:keyword])
      entry[:html] = html_by_keyword(keyword)

      locals = {
        entry: entry,
      }
      erb :keyword, locals: locals
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)

      unless db.xquery(%| SELECT * FROM entry WHERE keyword = ? LIMIT 1 |, keyword).first
        halt(404)
      end

      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)

      redirect_found '/'
    end

    post '/stars' do
      keyword = params[:keyword]
      db.xquery(%| select 1 from entry where keyword = ? limit 1 |, keyword).first or halt(404)

      redis.rpush(redis_key_for_star(keyword), params[:user])

      content_type :json
      JSON.generate(result: 'ok')
    end
  end
end
