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
      addhashtags: "never",
      notthistags: [],
      smarthashtags: true,
      addlink: "always",
      shrtfy: "always"
    }
  end

  def initialize(options = {})
    @options = default_options
    @options[:configfile] = options[:configfile] if options.has_key?(:configfile)

    config_file = YAML.load_file(@options[:configfile])

    @options.merge!(config_file['main'].inject({}){|resulthash,(k,v)| resulthash[k.to_sym] = v; resulthash})
    # reading options from config file, converting string keys to symbols in process

    @options.merge!(options)

    if @options.has_key?(:username) and ! @options.has_key?(:rssurl)
      @options[:rssurl] = "http://rss.juick.com/#{@options[:username]}/blog"
    end

    @options[:checkinterval] = @options[:checkinterval].to_i
    # just in case

    @options[:smarthashtags] = false if (@options[:addhashtags] == "never")

    @options[:postsonstart] = 1 if @options[:oneshot] && @options[:postsonstart] == 0

    Twitter.configure do |config|
      config_file['twitter'].each do |key, value|
        config.instance_variable_set("@#{key}", value)
      end
    end

    unless @options.include? :rssurl
      warn "RSS URL is not set"
      exit 1
    end

    begin
      doc = Nokogiri::XML(open(@options[:rssurl]))
      @old_items_guids = doc.css('item').map{|i| i.css('guid').text}.drop(@options[:postsonstart])
    rescue Exception => e
      warn "Can't fetch and parse #{@options[:rssurl]}: #{e.message}"
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

    try_add_to_tweet = lambda do |s, l=s.length|
      return true if s.empty?
      if (@used_text_length + l) <= @available_text_length
        @used_text_length += l + 1
        @tweet << s
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
          #puts bq.methods
          bq.replace("«#{bq.text}»")
        end

        media = (item.xpath('media:content').first || {})['url']
        text = description.xpath("//text()").text
        link = item.css('link').text

        @tags = []
        @tags = item.css('category').map{|c| Unicode::downcase(c.text).gsub('-','')}
        next unless (@tags & @options[:noreposttags]).empty?
        @tags = @tags - @options[:notthistags]

        is_links_type = ! (@tags & @options[:linkstags]).empty?
        @tags = @tags - @options[:linkstags]

        link = '' if is_links_type

        #puts ":#{link} #{media} #{text} #{@tags.map {|t| "#"+t}.join(' ')}"

        text = "#{media} #{text}"

        @available_text_length = 140
        @used_text_length = 0
        @tweet = []

        @available_text_length -= 21 if (@options[:addlink] == "always") && ! is_links_type
        @available_text_length -= @tags.inject(0){|total, t| total + t.length + 2} if @options[:addhashtags] == "always"
        need_shrtfy_this_text = (@options[:shrtfy] == "always" || (@options[:shrtfy] == "if-needed" && text.gsub(/http[^ ]*/, 'h'*20).length > @available_text_length))
        @available_text_length -= 21 if (@options[:addlink] == "if-shrtfd") && need_shrtfy_this_text

        wrds= {"бы" => "б", "же" => "ж", "да" => "д"}

        text.split(' ').each do |word|
          became_hashtag = false
          if word.start_with? 'http'
            word_length = 20
          else
            hashtag_proto = Unicode::downcase(word.gsub(/["()«».,;:…—]+/, ''))
            bonus_for_hashtag_in_text = @options[:addhashtags] == "always" ? hashtag_proto.length + 2 : 0
            if @options[:smarthashtags] && @tags.include?(hashtag_proto) && (@used_text_length + word.length + 1) <= (@available_text_length + bonus_for_hashtag_in_text)
                                           #our word can become hashtag                          #after cleaning some space this newborn hashtag will fit
              word = word.gsub(/\A([«("]*)[#]*/,'\1#')
              @tags.delete(hashtag_proto)                 #remove hashtag from tags array
              @available_text_length += bonus_for_hashtag_in_text #…and add some space for text if it was used
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

        @available_text_length = 140

        try_add_to_tweet.call(link, 20) if @options[:addlink] == "always" || (@options[:addlink] == "if-shrtfd" && need_shrtfy_this_text)
        @tags.map{|t| "#"+t}.each{|t| try_add_to_tweet.call(t)} if @options[:addhashtags] == "always"
        try_add_to_tweet.call(link, 20) if @options[:addlink] == "if-possible"
        @tags.map{|t| "#"+t}.each{|t| try_add_to_tweet.call(t)} if @options[:addhashtags] == "if-possible"

        @tweet.join(' ')
      end
    end.reject(&:nil?)
  end

  def run!
    @twitter_queue = []
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
  opts.banner = "Usage: jck2twtr [-h] [-c] [-u] [-r]"
  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end

  opts.on( '-c', '--config FILE', "Config file" ) do |f|
    options[:configfile] = f
  end

  opts.on( '-u', '--juick-username USERNAME', "Username on Juick" ) do |f|
    options[:username] = f
  end

  opts.on( '-r', '--rss-url URL', "RSS URL to parse (default: http://rss.juick.com/USERNAME/blog)" ) do |f|
    options[:rssurl] = f
  end

  opts.on( '-i', '--check-interval SECONDS', Integer, "Check interval in seconds, default 900 (15 min)" ) do |f|
    options[:checkinterval] = f
  end

  opts.on( '-p', '--posts-on-start NUM', Integer, "Proceed NUM posts immediately" ) do |f|
    options[:postsonstart] = f
  end

  opts.on( '-j', '--[no-]just-show', "Don't post to twitter, just put them to STDOUT. Also, jck2twtr wouldn't daemonize" ) do |f|
    options[:justshow] = f
  end

  opts.on( '-1', '--one-shot', "Exit after first rss fetch. Implies -p 1" ) do |f|
    options[:oneshot] = f
  end

  opts.on( '-s', '--shrtfy STRING', 'Shrtfy post text? May be "always" (default), "never" or "if-needed"' ) do |f|
    options[:shrtfy] = f
  end

  opts.on( '-n', '--norepost-tags tag1,tag2,…', Array, 'Juick posts with this tags will not be reposted. Default: "notwi"') do |f|
    options[:noreposttags] = f
  end

  opts.on(       '--links-tags tag1,tag2,…', Array, '"Links-type" tags. Default: "links,pics"') do |f|
    options[:linkstags] = f
  end

  opts.on( '-l', '--add-link STRING', 'Add link to post on juick. May be "always" (default, except links-type posts), "never" or "if-possible".' ) do |f|
    options[:addlink] = f
  end

  opts.on( '-t', '--add-hashtags STRING', 'Convert juick tags to twitter hashtags? May be "always", "never" (default), "if-possible" or "only-smart-hashtags"') do |f|
    options[:addhashtags] = f
  end

  opts.on(       '--not-this-tags tag1,tag2,…', Array, "List of tags, which you don't want use as hashtags" ) do |f|
    options[:notthistags] = f
  end

  opts.on(       '--[no-]smart-hashtags', 'If possible, convert words in post to respective hashtags. Default: true') do |f|
    options[:smarthashtags] = f
  end

  opts.on(       '--test', 'Combination of -j -1 -p 100' ) do |f|
    options[:justshow] = true
    options[:oneshot] = true
    options[:postsonstart] = 100
  end

end

trap("INT") do
  puts "Shutting down…"
  exit
end

optparse.parse!

Process.daemon(true,false) unless options[:justshow]

j2t = Jck2Twtr.new(options)
j2t.run!