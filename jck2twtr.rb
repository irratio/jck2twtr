# coding: utf-8
require "rubygems"
require "bundler/setup"
require "nokogiri"
require "open-uri"
require "twitter"
require "unicode"
require "yaml"

module Jck2Twtr
  module ClassMethods  
    def configure 
      config_file = YAML.load_file("config.yml")

      Twitter.configure do |config|
        config_file['twitter'].each do |key, value|
          config.instance_variable_set("@#{key}", value)
        end
      end
    end

    def already_posted
      false
    end

    def parse_rss
      doc = Nokogiri::XML(open('http://rss.juick.com/Irregular/blog'))
      items = doc.css('item')
      
      items.map do |item|
        return nil if already_posted
        
        description = Nokogiri::HTML(item.css('description').text)

        description.css('a').each do |a|
          a.replace(a['href'])
        end
        
        description.css('br').each do |br|
          br.replace(' ')
        end

        media = (item.xpath('media:content').first || {})['url']
        text = description.xpath("//text()").to_s
        link = item.css('link').text
            
        "#{link} #{media} #{text}"
      end.reject(&:nil?)
    end

    def create_tweet(item)
      tweet_real_length = 0
      tweet = []
      
      item.split(' ').each do |word|
        if word.start_with? 'http'
          word_length = 20
        else
          word_capitalized = Unicode::upcase(word.chr) == word.chr 
          word = word.gsub /[аеиоуыэюяьъ]+([^ \).,;:…!?»-])/i, '\1'  if word.length > 3
          word = word.gsub /["«».,;:…—-]+/, ''
          word_length = word.length 
          word = "#{Unicode::upcase(word.chr)}#{word[1..-1]}" if word_capitalized
        end
        
        next if word_length == 0
        
        if (tweet_real_length + word_length) <= 140
          tweet_real_length += word_length + 1
          tweet<< word
        else
          break
        end
      end
      
      tweet.join(" ")
    end

    def run!
      configure

      while true do
        parse_rss.map { |item| create_tweet(item) }.each do |tweet|
          puts tweet
          
          #Twitter.update(tweet)
        end
      end
    end
  end  
 
  extend ClassMethods
end

Jck2Twtr.run!