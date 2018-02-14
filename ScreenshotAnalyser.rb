require 'base64'
require 'json'
require 'net/https'
require 'csv'
require 'parallel'
require 'trigram'

GCP_API_KEY = ""
VISION_API_URL = "https://vision.googleapis.com/v1/images:annotate?key=#{GCP_API_KEY}"
REST_SEARCH_API_KEY = ''
HP_SEARCH_API_KEY = ''
MATCH_BORDER = 0.1
PARFECT_MATCH_BORDER = 1;
TARGET_placeapi_TYPE = ['bar','meal_delivery','meal_takeaway','cafe','restaurant','food','hair_care','point_of_interest']
NOISE_SYMBOL_CHAR = ['(',')','（','）','『','』','【','】','「','」','[',']'," ","　",'/',":",'%','#','$','&','·','~','.','-']

def get_shop_name_candidates_ocr(image)
  base64_image = Base64.strict_encode64(File.new(image, 'rb').read)

  body = {
    requests: [{
      image: {
        content: base64_image
      },
      features: [
        {
          type: 'TEXT_DETECTION',
          maxResults: 5
        }
      ]
    }]
  }.to_json

  hash = do_post(URI.parse(VISION_API_URL),body)
  shop_char =  hash["responses"][0]["textAnnotations"][0]["description"]
  shop_list = shop_char.rstrip.split(/\r?\n/).map {|line| line.chomp }
  p "[visionAPI result]candidate_list:#{shop_list}"
  return shop_list
end

=begin
def getGNaviShopInfo(shop_name)
  # ぐるなびへリクエスト
  uri = URI.parse URI.encode "https://api.gnavi.co.jp/RestSearchAPI/20150630/?keyid=#{REST_SEARCH_API_KEY}&format=json&name=#{shop_name}"
  result = do_get(shop_name,uri)
  shops_by_placeapi = []
  if !result['rest'].nil?
    for shop in result['rest'] do
      shops_by_placeapi.push("[[GNaviAPI]#{shop_name}]#{shop["name"]}")
    end
  end
  return shops_by_placeapi
end

def getHPShopInfo(shop_name)
  # ホットペッパーへリクエスト
  uri = URI.parse URI.encode "https://webservice.recruit.co.jp/hotpepper/shop/v1/?key=#{HP_SEARCH_API_KEY}&keyword=#{shop_name}&format=json"
  result = do_get(shop_name,uri)
  shops_by_placeapi = []
  if !result['results']['shop'].nil?
    for shop in result['results']['shop'] do
      shops_by_placeapi.push("[[HotPepper]#{shop_name}]#{shop["name"]}")
    end
  end
  return shops_by_placeapi
end
=end

#判定前に大文字小文字やカッコを除く
def format_shop_name(shop_name)

  if shop_name.nil? then
    return ''
  end

  for target_symbol in NOISE_SYMBOL_CHAR do
    shop_name = shop_name.delete(target_symbol)
  end
  shop_name = shop_name.downcase
  return shop_name
end

#3gram解析しているので２文字以下は完全一致かそうでないかで判定
def get_match_score(shop1,shop2)

  shop1 = format_shop_name(shop1)
  shop2 = format_shop_name(shop2)
  p shop1
  p shop2
  match =0
  if shop1.length <3 && shop2.length <3 then
    if shop1 == shop2 then
      match = 1.0
    end
  else
    match = Trigram.compare(shop1,shop2)
  end
  return match
end

def get_shop_candidates(placeapi_result)
  shop_candidates = []
  unless placeapi_result['results'].nil?
    for shop in placeapi_result['results'] do
      is_contain_restaurant = false
      for type in shop['types'] do
        is_contain_restaurant = TARGET_placeapi_TYPE.include?(type)
        break if is_contain_restaurant
      end
      if is_contain_restaurant then
        shop_candidates.push(shop["name"])
      end
    end
  end
  return shop_candidates
end

def get_gp_shop_info(place_search_target_shop)

  #ハッシュタグが付くと店名検索もできない場合もあるので、除く
  place_search_target_shop =  place_search_target_shop.delete('#')

  uri = URI.parse URI.encode "https://maps.googleapis.com/maps/api/place/textsearch/json?query=#{place_search_target_shop}&language=ja&key=#{GCP_API_KEY}"
  p "[place_search_target_shop]#{place_search_target_shop}"
  placeapi_result = do_get(uri)
  p placeapi_result
  shop_candidates = get_shop_candidates(placeapi_result)
  shops_by_placeapi = []
  #placeAPIで１件のみ一致の場合はたとえngramで一致度が低いとしても、同一の可能性が非常に高いので結果に入れる
  if shop_candidates.size == 1 then
    match = get_match_score(place_search_target_shop,shop_candidates[0])
    p "[GooglePlacesAPI][can select unique shop][#{place_search_target_shop}]#{shop_candidates[0]}[#{match}]"
    shops_by_placeapi.push(shop_candidates[0])
  else
    for shop_candidate in shop_candidates do
      match = get_match_score(shop_candidate,place_search_target_shop)
      p "[GooglePlacesAPI][#{place_search_target_shop}]#{shop_candidate}[#{match}]"
      if match>=MATCH_BORDER then
        if match == PARFECT_MATCH_BORDER then
          #完全一致の場合は１件だけ返すので、配列初期化
          shops_by_placeapi = []
          shops_by_placeapi.push(shop_candidate)
          break
        end
        shops_by_placeapi.push(shop_candidate)
      end
    end
  end

  return shops_by_placeapi
end

def do_get(uri)
  https = Net::HTTP.new(uri.host, uri.port)
  https.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  request["Content-Type"] = "application/json"
  response = https.request(request)
  return JSON.parse(response.body)
end

def do_post(uri,body)
  https = Net::HTTP.new(uri.host, uri.port)
  https.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri)
  request["Content-Type"] = "application/json"
  response = https.request(request,body)
  return JSON.parse(response.body)
end

def is_not_target(target)
  uri = URI.parse("https://language.googleapis.com/v1beta1/documents:analyzeEntities?key=#{GCP_API_KEY}")
  https = Net::HTTP.new(uri.host, uri.port)
  https.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri)
  request["Content-Type"] = "application/json"
  #ハッシュタグが付くと店名検索もできない場合もあるので、除く
  formatted_target =  target.delete('#')
  body  = {
              document:{
                      type:"PLAIN_TEXT",
                      content: formatted_target
                    }
                  }.to_json
  response = https.request(request, body)
  result = JSON.parse(response.body)
  p result
  return result['entities'].empty?
end

def is_partial_match(answer_shop_name,shops_by_placeapi)
  for shop in shops_by_placeapi do
    if get_match_score(answer_shop_name,shop) > MATCH_BORDER then
      return true
    end
  end
    return false
end

def main()
  output_csv = CSV.open('result.csv','w')
  input_csv = CSV.read('shopInfo.csv',headers:true)
  Parallel.each(input_csv,in_thread:100){|input_csv_row|
  target_image_name = Dir.glob("./img/#{input_csv_row[0]}")[0]
  p "debug #{target_image_name}"
  if !target_image_name.nil? then
    shops_by_placeapi = [];
    p "Start input_csv_row analysis:#{target_image_name}"
    shop_candidates_ocr = get_shop_name_candidates_ocr(target_image_name)
      for shop_name in shop_candidates_ocr do
        if !is_not_target(shop_name) then
            p "[Nature Language API result]target:#{shop_name}"
            shops_by_placeapi.concat(get_gp_shop_info(shop_name))
        end
      end
    shops_by_placeapi = shops_by_placeapi.uniq
    p "[csv]#{input_csv_row}"
    answer_shop_name = input_csv_row[1]
    output_csv.puts [input_csv_row[0],answer_shop_name,input_csv_row[2],shops_by_placeapi]
    match =  get_match_score(answer_shop_name,shops_by_placeapi[0])
    p match
    if shops_by_placeapi.size == 1 then
      if match > MATCH_BORDER then
        p "[Result]perfectMatch"
      else
        p "[Result]onlyMatch"
      end
    else
      if is_partial_match(answer_shop_name,shops_by_placeapi) then
        p "[Result]partialMatchCount"
      else
        p "[Result]failCount"
      end
    end
    p input_csv_row[0]
  end
  }
  output_csv.close
end

p 'start'
start_time = Time.now
main()
p "処理時間 #{Time.now - start_time}s"
p 'finish!'
