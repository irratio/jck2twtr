#!/usr/bin/env ruby
# coding: utf-8
$VERBOSE = nil
require "rubygems"
require "bundler/setup"
require "nokogiri"
require "open-uri"
require "twitter"
require "unicode"
require "yaml"
require "optparse"
require "date"
$VERBOSE = false

class Jck2Twtr
  def default_options
    {
      configfile: "config.yml",
      checkinterval: 900,
      postsonstart: 0,
      noreposttags: %w(notwi),
      linkstags: %w(links pics),
      addhashtags: :never,
      notthistags: [],
      smarthashtags: true,
      addlink: :always,
      shrtfy: :always
    }
  end

  def initialize(options = {})
    @options = default_options
    @options[:configfile] = options[:configfile] if options.has_key?(:configfile)

    config_file = YAML.load_file(@options[:configfile])

    @options.merge!(config_file[:main].inject({}){|resulthash,(k,v)| resulthash[k.to_sym] = v; resulthash})
    # reading options from config file, converting string keys to symbols in process

    @options.merge!(options)

    if @options.has_key?(:username) and ! @options.has_key?(:rssurl)
      @options[:rssurl] = "http://rss.juick.com/#{@options[:username]}/blog"
    end

    @options[:checkinterval] = @options[:checkinterval].to_i
    # just in case

    @options[:smarthashtags] = false if (@options[:addhashtags] == :never)

    @options[:postsonstart] = 1 if @options[:oneshot] && @options[:postsonstart] == 0

    @twitter = Twitter::Client.new(config_file[:twitter])
    @twitter_queue = []

    unless @options.include? :rssurl
      warn "RSS URL is not set"
      exit 1
    end

    @old_items_guids = []
  end

  def connected?
    begin
      doc = Nokogiri::XML(open(@options[:rssurl]))
      @old_items_guids = doc.css('item').map{|i| i.css('guid').text}.drop(@options[:postsonstart])
    rescue Exception => e
      warn "Can't fetch and parse #{@options[:rssurl]}: #{e.message}"
      return false
    end

    begin
      @twitter.verify_credentials
    rescue Exception => e
      warn "Can't connect to twitter: #{e.message}"
      return false
    end

    true
  end

  def save_config
    config_file_path = @options[:saveconfig].to_s.empty? ? @options[:configfile] : @options[:saveconfig]

    config = {:twitter=> Hash[ [:consumer_key,
                                :consumer_secret,
                                :oauth_token,
                                :oauth_token_secret].collect{|v| [v, @twitter.instance_variable_get("@#{v}")]} ],
              :main=> @options}
    config[:main].delete(:configfile)
    config[:main].delete(:saveconfig)

    begin
      File.open(config_file_path, "w") do |file|
        YAML.dump(config, file)
      end
    rescue Exception => e
      warn "Can't save config file to #{config_file_path}: #{e.message}"
      exit 2
    end
  end

  def parse_rss
    begin
      doc = Nokogiri::XML(open(@options[:rssurl]))
      items = doc.css('item')
    rescue Exception => e
      warn "Can't fetch #{@options[:rssurl]}: #{e.message}"
      return []
    end

    available_text_length = 140
    used_text_length = 0
    tweet = []

    try_add_to_tweet = lambda do |s, l=s.length|
      return true if s.empty?
      if (used_text_length + l) <= available_text_length
        used_text_length += l + 1
        tweet << s
        true
      else
        false
      end
    end

    items.map do |item|
      if @old_items_guids.include?(item.css('guid').text)
        nil
      else
        @old_items_guids.insert(0,item.css('guid').text)
        @old_items_guids.slice!(50,50)

        description = Nokogiri::HTML(item.css('description').text)

        description.css('a').each do |a|
          a.replace(a['href'])
        end

        description.css('br').each do |br|
          br.replace(' ')
        end

        description.css('blockquote').each do |bq|
          bq.replace("«#{bq.text}»")
        end

        media = (item.xpath('media:content').first || {})['url']
        text = description.xpath("//text()").text
        link = item.css('link').text

        tags = item.css('category').map{|c| Unicode::downcase(c.text).gsub('-','')}
        next unless (tags & @options[:noreposttags]).empty?
        tags = tags - @options[:notthistags]

        is_links_type = ! (tags & @options[:linkstags]).empty?
        tags = tags - @options[:linkstags]

        link = '' if is_links_type

        text = "#{media} #{text}"
        text.gsub! /[.]{2,}/, '…'

        available_text_length = 140
        used_text_length = 0
        tweet = []

        available_text_length -= 21 if (@options[:addlink] == :always) && ! is_links_type
        available_text_length -= tags.inject(0){|total, t| total + t.length + 2} if @options[:addhashtags] == :always
        need_shrtfy_this_text = (@options[:shrtfy] == :always || (@options[:shrtfy] == :"if-needed" && text.gsub(/http[^ ]*/, 'h'*20).length > available_text_length))
        available_text_length -= 21 if (@options[:addlink] == :"if-shrtfd") && need_shrtfy_this_text

        wrds= {"бы" => "б", "же" => "ж", "да" => "д"}

        text.split(' ').each do |word|
          became_hashtag = false
          if word.start_with? 'http'
            word_length = 20
          else
            hashtag_proto = Unicode::downcase(word.gsub(/["()«».,;:…—]+/, ''))
            bonus_for_hashtag_in_text = @options[:addhashtags] == :always ? hashtag_proto.length + 2 : 0
            if @options[:smarthashtags] && tags.include?(hashtag_proto) && (used_text_length + word.length + 1) <= (available_text_length + bonus_for_hashtag_in_text)
                                           #our word can become hashtag && after cleaning some space this newborn hashtag will fit
              word = word.gsub(/\A([«("]*)[#]*/,'\1#')
              tags.delete(hashtag_proto)                         #remove hashtag from tags array
              available_text_length += bonus_for_hashtag_in_text #…and add some space for text if it was used
              became_hashtag = true
            end
            if need_shrtfy_this_text
              word = word.gsub /[".,;:…—]+/, ''
              unless became_hashtag
                word_capitalized = Unicode::upcase(word.chr) == word.chr
                word.gsub! /!+1*(стоодиннадцать|одиннадцать|один|адыннадцать|адынацать|адын|thousand|hundred|eleven|one)*\z/, '!'
                word.gsub! /([^0-9])\1+/, '\1'
                word.gsub! /([^\Aьъ])[еюя]([^ \).,;:…!?»-])/i, '\1\2'  if word.length > 3
                word.gsub! /[аиоуыэьъ]+([^ \).,;:…!?»-])/i, '\1'  if word.length > 3
                word.gsub! /[aeiouy]+([^ \).,;:…!?»-])/i, '\1' if word.length > 3
                word.gsub! /[-]/, ''
                word = wrds[word] if wrds.include?(word)
                word = "#{Unicode::upcase(word.chr)}#{word[1..-1]}" if word_capitalized
              end
            end
            word_length = word.length
          end

          next if word_length == 0

          try_add_to_tweet.call(word, word_length) or break
        end

        available_text_length = 140

        try_add_to_tweet.call(link, 20) if @options[:addlink] == :always || (@options[:addlink] == :"if-shrtfd" && need_shrtfy_this_text)
        tags.map{|t| "#"+t}.each{|t| try_add_to_tweet.call(t)} if @options[:addhashtags] == :always
        try_add_to_tweet.call(link, 20) if @options[:addlink] == :"if-possible"
        tags.map{|t| "#"+t}.each{|t| try_add_to_tweet.call(t)} if @options[:addhashtags] == :"if-possible"

        tweet.join(' ')
      end
    end.reject(&:nil?)
  end

  def run!
    connected? or exit 2
    loop do
      parse_rss.reverse.each do |tweet|
        if @options[:justshow]
          puts "#{tweet}"
        else
          @twitter_queue.push(tweet)
        end
      end
      @twitter_queue.reject! do |tweet|
        Twitter.update(tweet)
      end
      break if @options[:oneshot]
      sleep(@options[:checkinterval])
    end
  end

end

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Program for reposting from juick to twitter with some text conversions\n" +
                "Usage: jck2twtr [-c CONFIGFILE] [-u USERNAME] [OPTIONS]"
  opts.set_summary_indent("  ")
  opts.on( '-h', '--help', 'display this screen' ) do
    puts opts
    exit
  end

  opts.on( '-c', '--config FILE', "path to config file" ) do |f|
    options[:configfile] = f
  end

  opts.on(       '--save-config [FILE]', 'save given options to config file and exit' ) do |f|
    options[:saveconfig] = f || ''
  end

  opts.on( '-u', '--juick-username USERNAME', "Username on Juick" ) do |f|
    options[:username] = f
  end

  opts.on( '-r', '--rss-url URL', "RSS URL (default: http://rss.juick.com/USERNAME/blog)" ) do |f|
    options[:rssurl] = f
  end

  opts.on( '-i', '--check-interval SECONDS', Integer, "check interval in seconds, default 900 (15 min)" ) do |f|
    options[:checkinterval] = f
  end

  opts.on( '-p', '--posts-on-start NUM', Integer, 'proceed NUM posts immediately',
           '(by default, all "old" posts are discarded)' ) do |f|
    options[:postsonstart] = f
  end

  opts.on( '-j', '--[no-]just-show', "don't post to twitter, just print to STDOUT.",
           "also, jck2twtr wouldn't daemonize" ) do |f|
    options[:justshow] = f
  end

  opts.on( '-1', '--one-shot', "exit after first rss fetch, implies -p 1" ) do |f|
    options[:oneshot] = f
  end

  opts.on( '-s', '--shrtfy STRING', [:always, :never, :"if-needed"], 'shrtfy post text? may be "always" (default), ',
           '"never" or "if-needed"' ) do |f|
    options[:shrtfy] = f
  end

  opts.on( '-n', '--norepost-tags tag1,tag2,…', Array, 'juick posts with this tags will not be reposted, default: "notwi"') do |f|
    options[:noreposttags] = f
  end

  opts.on(       '--links-tags tag1,tag2,…', Array, '"links-type" tags, default: "links,pics"') do |f|
    options[:linkstags] = f
  end

  opts.on( '-l', '--add-link STRING', [:always, :never, :"if-possible", :"if-shrtfd"], 'add link to original juick post? may be "always" (default),',
           '"never", "if-possible" or "if-shrtfd".' ) do |f|
    options[:addlink] = f
  end

  opts.on( '-t', '--add-hashtags STRING', [:always, :never, :"if-possible", :"only-smart-hashtags"], 'convert juick tags to twitter hashtags? may be "always",',
           '"never" (default), "if-possible" or "only-smart-hashtags"') do |f|
    options[:addhashtags] = f
  end

  opts.on(       '--not-this-tags tag1,tag2,…', Array, "list of tags which you don't want use as hashtags" ) do |f|
    options[:notthistags] = f
  end

  opts.on(       '--[no-]smart-hashtags', 'if possible, convert words in post to respective hashtags') do |f|
    options[:smarthashtags] = f
  end

  opts.on(       '--test', 'combination of -j -1 -p 100' ) do |f|
    options[:justshow] = true
    options[:oneshot] = true
    options[:postsonstart] = 100
  end

end

trap("INT") do
  puts "Shutting down…"
  exit
end

begin
  optparse.parse!
rescue OptionParser::ParseError => e
  warn e.message
  exit 1
end

j2t = Jck2Twtr.new(options)
if options[:saveconfig]
  j2t.save_config
else
  j2t.run!
end

Process.daemon(true,false) unless options[:justshow]