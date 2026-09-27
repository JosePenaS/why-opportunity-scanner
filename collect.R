# Direct Google Trends collection. Adapted from your Windows curl.exe approach.
# Only this scanner's output directory is written; no Quarto files are changed.
library(jsonlite)
library(httr2)
seed <- 'why'
geo <- 'US'
windows <- c('1h'='now 1-H','4h'='now 4-H','24h'='now 1-d','7d'='now 7-d')
output_dir <- file.path('why_scanner','output')
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
now <- function() format(Sys.time(),'%Y-%m-%dT%H:%M:%OS3Z',tz='UTC')
scan_id <- Sys.getenv('WHY_SCAN_ID')
if (!nzchar(scan_id)) scan_id <- paste0('gh-',Sys.getenv('GITHUB_RUN_ID',format(Sys.time(),'%Y%m%d%H%M%S')), '-', Sys.getenv('GITHUB_RUN_ATTEMPT','1'))
if (!grepl('^[A-Za-z0-9_-]{1,100}$',scan_id)) stop('Invalid scan ID')
cookies <- tempfile(fileext='.cookies')
`%||%` <- function(x,y) if(is.null(x)||length(x)==0) y else x
get_text <- function(url) {
 out <- tempfile(); headers <- tempfile()
 on.exit(unlink(c(out,headers)),add=TRUE)
 args <- c('--silent','--show-error','--location','--compressed',
 '--user-agent', shQuote('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'),
 '--header',shQuote('Accept: application/json,text/plain,*/*'),
 '--header',shQuote('Accept-Language: en-US,en;q=0.9'),
 '--header',shQuote('Referer: https://trends.google.com/'),
 '--cookie-jar',shQuote(cookies),'--cookie',shQuote(cookies),
 '--connect-timeout','20','--max-time','90','--dump-header',shQuote(headers),
 '--output',shQuote(out),'--write-out','%{http_code}',shQuote(url))
 result <- suppressWarnings(system2('curl.exe',args,stdout=TRUE,stderr=TRUE))
 status <- suppressWarnings(as.integer(tail(result,1)))
 if(is.na(status)||status<200||status>=300) stop(paste('Google Trends HTTP',status,'— collection unavailable. No automatic retry.'))
 if(!file.exists(out)) stop('Google Trends returned no response file')
 paste(readLines(out,warn=FALSE,encoding='UTF-8'),collapse='\n')
}
parse_json <- function(x) fromJSON(sub("^\\)\\]\\}',?\\s*",'',x),simplifyVector=FALSE)
url <- function(base,params) {r<-request(base);r<-do.call(req_url_query,c(list(r),params));r$url}
report <- list(schemaVersion=1L,scanId=scan_id,createdAt=now(),completedAt=NULL,geo=geo,seed=seed,
 source='Google Trends direct / Windows curl.exe',model=Sys.getenv('OPENAI_MODEL','gpt-5'),
 windows=list(),queries=list(),stories=list(),errors=list(),status='collecting')
save_report <- function() write_json(report,file.path(output_dir,'why-scan.json'),auto_unbox=TRUE,pretty=TRUE,null='null',na='null')
save_report()
session_error <- tryCatch({get_text('https://trends.google.com/trends/');NULL},error=function(e)conditionMessage(e))
blocked <- session_error
for(k in names(windows)) {
 message('Collecting ',k,' Rising related queries for US / why')
 result <- tryCatch({
 if(!is.null(blocked)) stop(blocked)
 req <- list(comparisonItem=list(list(keyword=seed,geo=geo,time=unname(windows[k]))),category=0L,property='')
 # Consistent UTC collection; the dashboard formats timestamps in America/Santiago.
 explore <- parse_json(get_text(url('https://trends.google.com/trends/api/explore',list(hl='en-US',tz=0L,req=toJSON(req,auto_unbox=TRUE)))))
 widget <- Filter(function(w)identical(w$id,'RELATED_QUERIES'),explore$widgets %||% list())
 if(length(widget)!=1L||is.null(widget[[1]]$token)) stop('Related queries widget unavailable')
 Sys.sleep(3)
 w <- widget[[1]]
 response <- parse_json(get_text(url('https://trends.google.com/trends/api/widgetdata/relatedsearches',list(hl='en-US',tz=0L,req=toJSON(w$request,auto_unbox=TRUE),token=w$token))))
 ranked <- response$default$rankedList
 if(is.null(ranked)||length(ranked)<2L||is.null(ranked[[2]]$rankedKeyword)) stop('Rising list unavailable; not evidence of zero interest')
 rows <- ranked[[2]]$rankedKeyword
 collected <- now()
 for(i in seq_along(rows)) {
 row <- rows[[i]];query<-row$query;growth<-row$formattedValue
 if(!is.character(query)||length(query)!=1L||!is.character(growth)||length(growth)!=1L) stop('Unexpected query or growth-label format')
 if(!grepl('^(Breakout|[+]?([0-9]+[,.]?)+%?)$',growth,ignore.case=TRUE)) stop('Unexpected growth label')
 }
 list(rows=rows,collected=collected)
 },error=function(e){msg<-conditionMessage(e);if(grepl('HTTP (403|429)',msg))blocked<<-msg;list(error=msg)})
 if(!is.null(result$error)) {
 report$windows[[k]] <- list(status='error',count=0L,collectedAt=now(),error=result$error)
 report$errors[[length(report$errors)+1L]] <- paste(k,result$error)
 } else {
 report$windows[[k]] <- list(status='ok',count=length(result$rows),collectedAt=result$collected,provider=report$source)
 for(i in seq_along(result$rows)) {
 r<-result$rows[[i]]
 report$queries[[length(report$queries)+1L]]<-list(id=paste0(k,'-',i),query=r$query,growth=r$formattedValue,window=k,rank=i,collected_at=result$collected)
 }
 }
 save_report()
 if(k!='7d'&&is.null(blocked)) Sys.sleep(15)
}
report$status <- if(length(report$queries)) 'collected' else 'failed'
report$completedAt <- now()
save_report()
unlink(cookies)
message('Collection saved. Queries: ',length(report$queries),'; unavailable windows: ',sum(vapply(report$windows,function(w)w$status!='ok',logical(1))))
