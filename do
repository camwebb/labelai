#!/bin/gawk -E

# labelai: Web app using AI to OCR and parse herbarium specimen labels
# https://github.com/camwebb/labelai/
# (c) 2023 Cam Webb <cw@camwebb.info>
# Licence: https://unlicense.org

@load "json"
@include "pw.awk"

BEGIN{

  init()
  
  header("Herbarium sheet OCR")

  if (ENVIRON["CONTENT_LENGTH"] > 10000000)
    fail("Image too large")
  
  # POST
  if (ENVIRON["CONTENT_TYPE"] ~ /form-data/)
    read_file()

  # GET
  else {
    split(ENVIRON["QUERY_STRING"], qs, "&")
    for (i in qs) {
      split(qs[i], qp, "=")
      f[qp[1]] = substr(urldecode(qp[2]),1,100)
    }
    
    if (f["method"] == "guid") {
      #! # check for misformed GUID
      #! if (f["guid"] !~ /^UAMb?:(Herb|Alg):[0-9]+$/)
      #!   fail("GUID of wrong form. Must be: \"^UAMb?:(Herb|Alg):[0-9]+$\"")
      guid2url()
      # check for no media
      if (!url[f["guid"]])
        fail("No JPEG image for that GUID")
      Imgurl = url[f["guid"]]
    }
    
    else
      defaulttext()
  }

  # check for language ; NOTE: specifying language does not seem to help
  if (!f["lang"])
    fail("No Language specified")

  pw()
  "curl -s -X POST "                                                    \
    "-H 'Authorization: Bearer " APITOKEN "' "                          \
    "-H 'Content-Type: application/json' "                              \
    "-d '{\"providers\": \"google\",\"language\": \"" f["lang"] "\", "  \
    "\"file_url\": \"" Imgurl                                           \
    "\"}' https://api.edenai.run/v2/ocr/ocr"                            \
    | getline json

  if (!json::from_json(json, data))
    fail("ERROR: API Query or JSON import failed.")
  if (data["google"]["status"] == "fail")
    fail(data["google"]["error"]["message"])

  if (f["guid"])
    print "<p style=\"float: right;\"><a target=\"_blank\" href=\"" Imgurl \
      "\"><img style=\"max-height:500px;max-width:300px;\" src=\"" Imgurl "\" /></a>" \
      "<br/>(Click on image to open in new tab)</p>" 
  
  print "<p><button onclick=\"showocr()\">Show OCR text</button></p>"
  print "<p id=\"ocr\" style=\"border: thin silver solid; padding:20px; " \
    "font-family:monospace;width:500px;display:none;\">"                       \
    data["google"]["text"] "</p>"
  
  # add translation if Russian
  if (f["lang"] != "en") {
    "curl -s -X POST "                                                  \
      "-H 'Authorization: Bearer " APITOKEN "' "                        \
      "-H 'Content-Type: application/json' "                            \
      "-d '{\"providers\": \"google\",\"source_language\": \"" f["lang"] \
      "\", \"target_language\":\"en\", \"text\": \""                    \
      data["google"]["text"] "\"}' "                                    \
      "https://api.edenai.run/v2/translation/automatic_translation"     \
      | getline json
    
    if (!json::from_json(json, data))
      fail("ERROR: API Query or JSON import failed.")
    if (data["google"]["status"] == "fail")
      fail(data["google"]["error"]["message"])

    print "<p><button onclick=\"showtrans()\">Show Translation</button></p>"
    print "<p id=\"trans\" style=\"border: thin silver solid; padding:20px; " \
      "font-family:monospace;width:500px;display:none;\">"                     \
      data["google"]["text"] "</p>"
  }

  # generative AI
  #! gsub(/ONE DECIMETER ONE CUBIC DECIMETER OF WATER WEIGHTS ONE KILOGRAM AND MEASURES ONE LITER. MADE IN GERMANY mm [0-9 ]+/,"",data["google"]["text"])
  gsub(/["']/," ", data["google"]["text"])
  "curl -s -X POST "                                                    \
    "-H 'Authorization: Bearer " APITOKEN "' "                          \
    "-H 'Content-Type: application/json' "                              \
    "-d '{\"providers\": \"openai\",\"max_tokens\": 500,\"temperature\":0," \
    "\"model\": {\"openai\":\"text-davinci-003\"}, \"text\": \""        \
    Pretxt data["google"]["text"] Posttxt "\"}' "                      \
    "https://api.edenai.run/v2/text/generation" | getline json
  
  if (!json::from_json(json, data))
    fail("ERROR: API Query or JSON import failed.")
  if (data["openai"]["status"] == "fail")
    fail(data["openai"]["error"]["message"])

  print "<p><button onclick=\"showai()\">Show AI output</button></p>"
  print "<p id=\"ai\" style=\"border: thin silver solid; padding:20px; "    \
    "font-family:monospace;width:500px;display:none;\">"                       \
    data["openai"]["generated_text"] "</p>"

  # make table
  if (!json::from_json(data["openai"]["generated_text"], data))
    fail("ERROR: API Query or JSON import failed.")

  # mapping
  gsub(/dwc:/,"",data["openai"]["generated_text"])
  for (i = 1; i <= length(Field); i++)
    for (j = 1; j <= length(FieldAI[i]); j++)
      if (data[FieldAI[i][j]] && !d[Field[i]])
        d[Field[i]] = data[FieldAI[i][j]]
  if (f["method"] == "guid")
    d["arctos_guid"] = f["guid"]

  # clean dates
  for (i = 1; i <= length(Field); i++)
    if (Field[i] ~ /date/)
      d[Field[i]] = substr(d[Field[i]],1,10)
  
  print "<table style=\"border: thin silver solid; padding:20px; "  \
    "font-family:monospace;min-width:650px;\">"
  
  for (i = 1; i <= length(Field); i++)
    print "<tr><td>" Field[i] "</td><td><input type=\"text\" id=\"i_"   \
      Field[i] "\" style=\"width:450px;\" value=\"" d[Field[i]]         \
      "\"/></td><td><button onclick=\"clear_" Field[i] \
      "()\">x</button>" \
      ((Field[i]=="elevation") ?                                \
       " <button onclick=\"ft2m()\">f2m</button>" : "")   \
      "</td></tr>"
  print "</table><br/>"

  printf "<pre style=\"font-size:8px;\">"
  for (i = 1; i <= length(Field); i++)
    printf "<span id=\"o_%s\">%s</span>&#9;",Field[i], d[Field[i]]
  print "</pre>"
  print "<br/><br/><p>[ <a href=\"do\">BACK</a> ]</p>"
  footer()

  # delete local file
  if (!f["guid"])
    system("rm -f " gensub(/[ /]+$/,"","G",RELIMG) "/" PROCINFO["pid"] ".jpg")
}

function read_file(   field, resp, file) {

  RS="\r\n"
  while(getline < "/dev/stdin") {
    if ($0 ~ /^[Cc]ontent-[Dd]isposition/)
      field = gensub(/.* name="([^"]+)".*/, "\\1","G",$0)
    else if ($0 == "") {
      getline < "/dev/stdin"
      # if there are newlines in an image:
      while ($0 !~ /^----+/) {
        f[field] = f[field] RS $0
        getline < "/dev/stdin"
      }
      gsub(/^\r\n/,"",f[field])
    }
  }

  # NB: mkdir ../tmp && chmod a+w ../tmp
  file = gensub(/[ /]+$/,"","G",RELIMG) "/" PROCINFO["pid"] ".jpg"
  print f["image"] > file
  fflush(file)
  delete f["image"]

  # test that the file is a jpeg
  "file " file | getline resp
  if (resp !~ /JPEG image/)
    fail("file submitted is not a JPEG image file")
  
  Imgurl = gensub(/[ /]+$/,"","G",PUBIMG) "/" PROCINFO["pid"] ".jpg"
}

function guid2url() {
  while (getline < "guid2url")
    url[$1] = $2
  # will overwrite if there are several media for each GUID. OK.
}

function defaulttext() {
  print "<h1>Herbarium sheet OCR</h1>"
  print "<form action=\"do\">"                                          \
    "<input type=\"hidden\" name=\"method\" value=\"guid\"/>"           \
    "<p>GUID: <input type=\"text\" name=\"guid\" style=\"width:150px;\"/>" \
    "&#160;&#160;Label language: <select name=\"lang\"> "                     \
    "<option value=\"en\" selected=\"1\">English</option> "             \
    "<option value=\"ru\">Russian</option>"                             \
    "</select>"                                                         \
    "&#160;&#160;&#160;<input type=\"submit\" value=\"Submit\"/>"       \
    "</p></form>"
  print "<p><i>or...</i></p>"
  print "<form action=\"do\" enctype=\"multipart/form-data\" method=\"post\">" \
    "<input type=\"hidden\" name=\"method\" value=\"file\"/>"           \
    "<p>Send file: <input onchange=\"validateSize(this)\" type=\"file\" name=\"image\" />"              \
    "&#160;&#160;Label language: <select name=\"lang\"> "               \
    "<option value=\"en\" selected=\"1\">English</option> "             \
    "<option value=\"ru\">Russian</option>"                             \
    "</select>"                                                         \
    "&#160;&#160;&#160;<input type=\"submit\" value=\"Submit\"/>"       \
    "</p></form>"
  footer()
  exit 0
}

function fail(text) {
  print "<p><b>" text "</b></p>"
  print "<br/><br/><p>[ <a href=\"do\">BACK</a> ]</p>"
  footer()
  exit 1
}

function header(title) {
  
  # Use html5
  print "Content-type: text/html\n"
  print "<!DOCTYPE html>"
  print "<html xmlns=\"http://www.w3.org/1999/xhtml\">"
  print "<head><title>" title "</title>"
  print "<meta http-equiv=\"Content-Type\" content=\"text/html; \
           charset=utf-8\" />"
  print "<link href=\"https://fonts.googleapis.com/css?family=Montserrat\" \
           rel=\"stylesheet\"/>"
  print "<link href=\"../img/akflora.png\" rel=\"shortcut icon\" \
           type=\"image/x-icon\"/>"
  print "<style>"
  print "div.main { font-size: 14px; font-family: 'Montserrat', "    \
    "Verdana, Arial, Helvetica, sans-serif; padding: 20px; padding-top:0px;" \
    "position: absolute ; min-width:1200px; max-width:1200px}"
  print "</style>\n<script type=\"application/javascript\">"
  print "function showocr() {var ocr = document.getElementById('ocr');         \
      if (ocr.style.display == 'none') { ocr.style.display = 'block'; } \
      else { ocr.style.display = 'none'; } }"
  print "function showai() {var ai = document.getElementById('ai');         \
      if (ai.style.display == 'none') { ai.style.display = 'block'; } \
      else { ai.style.display = 'none'; } }"
  print "function showtrans() {var trans = document.getElementById('trans'); \
      if (trans.style.display == 'none') { trans.style.display = 'block'; } \
      else { trans.style.display = 'none'; } }"
  print "function validateSize(input) { \
      if ((input.files[0].size / (1024 * 1024)) > 2) \
      {alert('File size exceeds 2 MiB; please downsize image first'); }}"
  print "function ft2m() \
      {var before = document.getElementById('i_elevation').value;         \
        document.getElementById('i_elevation').value = before / 3.28084 ; \
        document.getElementById('o_elevation').value = before / 3.28084 ; }"
  print "</script>"
  print "</head>\n<body><div class=\"main\">"
}


function footer() {
  if (f["method"]) {
    print "<script type=\"text/javascript\">"
    for (i = 1; i <= length(Field); i++) {
      print "var i_" Field[i] " = document.getElementById('i_"Field[i] "'); " \
        "var o_" Field[i]" = document.getElementById('o_" Field[i] "'); " \
        "i_" Field[i] ".addEventListener('input', function(event) { "   \
        "o_" Field[i] ".innerText = event.target.value; });"
      print "function clear_" Field[i] "() { document.getElementById('i_" \
        Field[i] "').value = '' ; document.getElementById('o_" \
        Field[i] "').innerHTML = '' ; }"
    }
    print "</script>"
  }
  print "</div></body>\n</html>";
}

function urldecode(text,   hex, i, hextab, decoded, len, c, c1, c2, code) {
  # based on Heiner Steven's http://www.shelldorado.com/scripts/cmds/urldecode
  split("0 1 2 3 4 5 6 7 8 9 a b c d e f", hex, " ")
  for (i=0; i<16; i++)
    hextab[hex[i+1]] = i
  decoded = "" ; i = 1 ; len = length(text)
  while ( i <= len ) {
    c = substr (text, i, 1)
    if ( c == "%" ) 
      if ( i+2 <= len ) {
        c1 = tolower(substr(text, i+1, 1)); c2 = tolower(substr(text, i+2, 1))
        if ( hextab [c1] != "" || hextab [c2] != "" ) {
          if ( ( (c1 >= 2) && ((c1 c2) != "7f") )   \
               || (c1 == 0 && c2 ~ "[9acd]") )
            c = sprintf("%c", 0 + hextab [c1] * 16 + hextab [c2] + 0)
          else
            c = " "
          i = i + 2
        }
      }
    else if ( c == "+" )
      c = " "
    decoded = decoded c
    ++i
  }
  gsub(/\r\n/, "\n", decoded);
  gsub(/\n*$/,"",decoded);
  return decoded
}

function init(       fields,i,j,n2,n4) {
  Pretxt = "In this text find: instituion code, identifier = regex [VBL][0-9]+, barcode = regex H[0-9]+, scientific name, locality, state, country, coordinates, elevation, habitat, first collector, collector code, associated collectors, collection date, identified by person, identification date [ "
  Posttxt = " ] and output mapped to Darwin Core terms, in JSON format, with all dates in ISO 2014 format, and all coordinates in decimal degrees, and all elevations in meters."

  fields = " \
    arctos_guid     : arctos_guid                                   |  \
    barcode         : barcode                                       |  \
    alaac           : catalogNumber, collectionNumber, identifier   |  \
    scientific_name : scientificName                                |  \
    locality        : locality                                      |  \
    state           : stateProvince                                 |  \
    country         : country                                       |  \
    latitude        : decimalLatitude, latitude                     |  \
    longitude       : decimalLongitude, longitude                   |  \
    elevation       : minimumElevationInMeters, elevation,             \
                      verbatimElevationInMeters, verbatimElevation,    \
                      elevationInMeters                             |  \
    habitat         : habitat                                       |  \
    collector       : recordedBy, collector                         |  \
    collector2      : associatedCollectors,  collectors             |  \
    collector3      : associatedCollectors,  collectors             |  \
    coll_number     : recordNumber, collectorsCode                  |  \
    coll_date       : eventDate, collectionDate                     |  \
    identified_by   : identifiedBy, identifier                      |  \
    identified_date : dateIdentified, identificationDate"
  gsub(/[\n ]/,"",fields)
  n2 = split(fields, fields2, "|")
  for (i = 1; i <= n2; i++) {
    split(fields2[i], fields3, ":")
    Field[i] = fields3[1]
    n4 = split(fields3[2], fields4, ",")
    for (j = 1; j <= n4; j++)
      FieldAI[i][j] = fields4[j]
  }
}
