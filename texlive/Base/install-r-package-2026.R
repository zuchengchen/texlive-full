# CPU 核心检测
cores <- parallel::detectCores()
cat("Detected CPU cores:", cores, "\n")
# 包级并行交给 install.packages(Ncpus)，单包内部编译限 -j4，避免并发乘积过载
jobs <- 4
Sys.setenv(MAKEFLAGS = paste0("-j", jobs))
cat("MAKEFLAGS =", Sys.getenv("MAKEFLAGS"), "\n")

# 如果没有 remotes 就安装
if (!requireNamespace("remotes", quietly = TRUE))
  install.packages("remotes", repos="https://packagemanager.posit.co/cran/2026-06-25")


# 安装 BiocManager 包
if (!requireNamespace("BiocManager", quietly = TRUE))
  remotes::install_version(
    "BiocManager",
    version = "1.30.27",
    repos = "https://packagemanager.posit.co/cran/2026-06-25",
    lib = "/usr/local/lib/R/site-library",
    Ncpus = parallel::detectCores(),
    upgrade = "never"
  )


# 只保留 knitr/rmarkdown 文档常用的包；依赖由 dated 快照自动解析。
# 原先 ~600 个包（OpenMx、rstan、sf、terra 等重型统计/GIS 包）占 ~4.4GB，已精简。
txt <- "
knitr 1.51
rmarkdown 2.31
markdown 2.0
formatR 1.14
highr 0.12
xfun 0.59
evaluate 1.0.5
tinytex 0.60
xtable 1.8-8
kableExtra 1.4.0
Hmisc 5.2-6
tikzDevice 0.12.6
ggplot2 4.0.3
tidyverse 2.0.0
data.table 1.18.4
scales 1.4.0
RColorBrewer 1.1-3
viridis 0.6.5
gridExtra 2.3.1
cowplot 1.2.0
patchwork 1.3.2
ggrepel 0.9.8
ggpubr 0.6.3
ggsci 5.0.0
latex2exp 0.9.8
reshape2 1.4.5
plyr 1.8.9
zoo 1.8-15
xts 0.14.2
readxl 1.5.0
openxlsx 4.2.8.1
haven 2.5.5
jsonlite 2.0.0
stargazer 5.2.3
texreg 1.39.5
broom 1.0.13
car 3.1-5
lme4 2.0-1
lmtest 0.9-40
sandwich 3.1-1
psych 2.6.5
corrplot 0.95
gt 1.3.0
table1 1.5.1
emmeans 2.0.3
forecast 9.0.2
Rcpp 1.1.1-1.1
magick 2.9.1
"

# 解析
lines <- trimws(strsplit(txt, "\n")[[1]])
lines <- lines[nchar(lines) > 0]

pkg <- sub(" .*", "", lines)
ver <- sub(".* ", "", lines)

repo <- "https://packagemanager.posit.co/cran/2026-06-25"
bioc_repos <- BiocManager::repositories()
bioc_avail <- rownames(available.packages(repos = bioc_repos[names(bioc_repos) != "CRAN"]))
is_bioc <- pkg %in% bioc_avail

# Bioc 包不在 CRAN 仓库里，必须先装：清单里的 NMF 依赖 Biobase，
# 若 CRAN 循环先跑，NMF 安装时 Biobase 还不存在。
# 安装 BIO 系列包
if (any(is_bioc)) {
  # Bioc 依赖里的 CRAN 包（如 pcaMethods 依赖 MASS）也必须走锁版本快照：
  # 最新 CRAN 的版本可能要求更新的 R，导致 "not available" 安装失败
  bioc_r <- BiocManager::repositories()
  bioc_r["CRAN"] <- repo
  options(repos = bioc_r)
  for (i in which(is_bioc)) {
    cat("Installing Bioconductor package", pkg[i], ver[i], "\n")
    try(
      BiocManager::install(
        pkg[i],
        lib = "/usr/local/lib/R/site-library",
        ask = FALSE,
        update = FALSE
      )
    )
  }
}

# 剩下的批量并行安装：dated 快照天然锁版本。先并行把源码包预下载成
# 本地仓库（消除逐包串行下载延迟），大包排到队首缩短收尾长尾；然后
# install.packages() 按依赖图生成 Makefile 拓扑排序并行编译。
options(timeout = 300)
todo <- pkg[!is_bioc]
ap <- available.packages(repos = repo)
cache <- "/tmp/pkg-cache/src/contrib"
dir.create(cache, recursive = TRUE, showWarnings = FALSE)
fetch <- todo[todo %in% rownames(ap)]
urls <- paste0(ap[fetch, "Repository"], "/", fetch, "_", ap[fetch, "Version"], ".tar.gz")
dest <- file.path(cache, basename(urls))
invisible(parallel::mcmapply(function(u, d) {
  for (k in 1:3) {
    ok <- tryCatch(download.file(u, d, quiet = TRUE) == 0, error = function(e) FALSE)
    if (ok && file.exists(d)) break
    unlink(d)
  }
}, urls, dest, mc.cores = cores, mc.preschedule = FALSE))
tools::write_PACKAGES(cache)
heavy <- intersect(c("igraph", "stringi", "rstan", "StanHeaders", "s2", "sf", "terra", "Matrix", "V8"), todo)
install.packages(
  c(heavy, setdiff(todo, heavy)),
  repos = c("file:///tmp/pkg-cache", repo),
  lib = "/usr/local/lib/R/site-library",
  Ncpus = parallel::detectCores()
)

# 上面批量装失败的包补装一遍（串行，安全）。个别 pin 与快照版本有微小
# 出入的直接用快照版本，不再逐包回装。
ip0 <- installed.packages()
miss <- setdiff(pkg[!is_bioc], rownames(ip0))
if (length(miss) > 0) {
  cat("Retrying failed packages:", paste(miss, collapse = " "), "\n")
  install.packages(
    miss,
    repos = c("file:///tmp/pkg-cache", repo),
    lib = "/usr/local/lib/R/site-library",
    Ncpus = parallel::detectCores()
  )
}

# 与清单版本不一致或仍缺失的，串行精确回装（冻结日快照下只剩 2~3 个）。
# 直接按 URL 取指定版本 tarball、repos=NULL 本地安装：不做任何依赖解析，
# 杜绝 remotes 之类把缺失依赖从 cloud CRAN 装成最新版（R 版本不兼容）的泄漏。
# 按字母序单轮跑会踩依赖顺序（car 依赖 maptools/rio，但 m/r 排在 c 之后），
# 多跑几轮直到没有新进展；链最深 3 层，5 轮上限绰绰有余。
for (round in 1:5) {
ip1 <- installed.packages(noCache = TRUE)
progress <- FALSE
for (i in seq_along(pkg)) {
  if (is_bioc[i]) next
  if (pkg[i] %in% rownames(ip1) && ip1[pkg[i], "Version"] == ver[i]) next
  fname <- paste0(pkg[i], "_", ver[i], ".tar.gz")
  urls <- c(
    paste0(repo, "/src/contrib/", fname),
    paste0(repo, "/src/contrib/Archive/", pkg[i], "/", fname),
    paste0("https://cloud.r-project.org/src/contrib/", fname),
    paste0("https://cloud.r-project.org/src/contrib/Archive/", pkg[i], "/", fname)
  )
  dest <- file.path(tempdir(), fname)
  got <- FALSE
  for (u in urls) {
    got <- tryCatch(download.file(u, dest, quiet = TRUE) == 0, error = function(e) FALSE)
    if (got && file.exists(dest)) break
    unlink(dest)
  }
  if (!got) { cat("Pinning", pkg[i], ver[i], ": tarball not found\n"); next }
  cat("Pinning", pkg[i], ver[i], "from", u, "\n")
  try(install.packages(dest, repos = NULL, type = "source",
                       lib = "/usr/local/lib/R/site-library"))
  unlink(dest)
  progress <- TRUE
}
if (!progress) break
}

# 检查
cat("\n===== Checking installed packages =====\n")

ip <- installed.packages()

missing <- c()

for(i in seq_along(pkg)){
  p <- pkg[i]
  v <- ver[i]

  if(!(p %in% rownames(ip))){
    missing <- c(missing, sprintf("%s %s (not installed)", p, v))
  } else {
    installed_v <- ip[p, "Version"]
    if(installed_v != v){
      missing <- c(missing, sprintf("%s %s (installed %s)", p, v, installed_v))
    }
  }
}

if(length(missing) == 0){
  cat("All packages installed correctly\n")
} else {
  cat("Packages missing or wrong version:\n")
  cat(paste(missing, collapse = "\n"), "\n")
}
