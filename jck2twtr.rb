# coding: utf-8
require "rubygems"
require "bundler/setup"
require "nokogiri"
require 'open-uri'

# Get a Nokogiri::HTML:Document for the page we’re interested in...

doc = Nokogiri::XML(open('http://rss.juick.com/Irregular/blog'))
items = doc.css('item')

items.each do |item|
  description = Nokogiri::HTML(item.css('description').text)
  description.css('a').each do |a|
    a.replace(a['href'])
  end
  puts media = (item.xpath('media:content').first || {})['url']
  puts text = description.xpath("//text()").to_s
  puts link = item.css('link').text
  
end
