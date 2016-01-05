
#####
#' Cross-validation for the empirical saddlepoint density
#' @description Performs cross-validation to choose the \code{decay} tuning parameters 
#'              which determines the mixture between a consistent and a Gaussian estimator
#'              of the Cumulant Generating Function (ECGF).
#'
#' @param decay Numeric vector containing the possible value of the tuning parameter.
#' @param simulate  Function with prototype \code{function(...)} that will be called \code{nrep} times
#'                  to simulate \code{d}-dimensional random variables. 
#'                  Each time \code{simulator} is called it will return a \code{n} by \code{d} matrix.
#' @param nrep Number of times the whole cross-validation procedure will be repeated, by calling
#'             \code{simulator} to generate random variable and computing the cross-validation score
#'             for every element of \code{decay}.
#' @param multicore  see \code{\link{smcmc-class}}.
#' @param ncores   see \code{\link{smcmc-class}}.
#' @param cluster an object of class \code{c("SOCKcluster", "cluster")}. This allowes the user to pass her own cluster,
#'                which will be used if \code{multicore == TRUE}. The user has to remember to stop the cluster. 
#' @param control A list of control parameters, with entries:
#'         \itemize{
#'         \item{ \code{K} }{The number of folds to be used in cross-validation. By defaults \code{K = 10};}
#'         \item{ \code{draw} }{ If \code{TRUE} the results of cross-validation will be plotted. \code{TRUE} by default;}
#'         \item{ \code{method} }{The method used to calculate the normalizing constant. 
#'                                Either "LAP" (laplace) or "IS" (importance sampling).}
#'         \item{ \code{tol} }{The tolerance used to assess the convergence of the solution to the saddlepoint equation.
#'                             The default is 1e-6.}
#'         \item{ \code{nNorm} }{ Number of simulations to be used in order to estimate the normalizing constant of the saddlepoint density.
#'                                By default equal to 1e3.}
#'         }
#' @return A list with entries:
#'         \itemize{
#'          \item{ \code{summary} }{ A matrix of summary results from the cross-validation procedure.  }
#'         \item{ \code{negLogLik} }{A matrix \code{length{decay}} by \code{control$K*nrep} where the i-th row represent the negative loglikelihood
#'                                   estimated for the i-th value of \code{decay}, while each column represents a different fold and repetition.}
#'         \item{ \code{normConst} }{ A matrix \code{length{decay}} by \code{nrep} where the i-th row contains the estimates of the normalizing constant.}
#'         }
#'         is returned invisibly.
#'         If \code{control$draw == TRUE} the function will also plot the cross-validation curve. 
#' @author Matteo Fasiolo <matteo.fasiolo@@gmail.com>.
#' @examples
#' 
#' # Saddlepoint is needed
#' selectDecay(decay = c(0.05, 0.1, 0.5, 1), 
#'             simulator = function(...) rgamma(100, 2, 1), 
#'             nrep = 4)
#'             
#' # Saddlepoint is not needed
#' selectDecay(decay = c(0.05, 0.1, 0.5, 1), 
#'             simulator = function(...) rnorm(100, 0, 1), 
#'             nrep = 4)
#' 
#' @export
#'

selectDecay <- function(decay, 
                        simulator,
                        K,
                        nrep = 1,
                        normalize = FALSE,
                        draw = TRUE,
                        multicore = !is.null(cluster),
                        cluster = NULL,
                        ncores = detectCores() - 1, 
                        control = list(),
                        ...)
{
  
  # Control list which will be used internally
  ctrl <- list( "fastInit" = FALSE,
                "method" = "IS", 
                "nNorm" = 1000 )
      
  # Checking if the control list contains unknown names, entries in "control" substitute those in "ctrl"
  ctrl <- .ctrlSetup(innerCtrl = ctrl, outerCtrl = control)
  
  if(ctrl$method == "LAP") stop("Laplace approximation is not supported by selectDecay() at the moment. Use \"IS\".")
  if(normalize && ctrl$nNorm == 0) stop("If \"normalize\" == TRUE, then control$nNorm must be > 0")
  
  if(ctrl$method == "LAP") stop("This function uses only importance sampling at the moment")
  
  if( multicore ){ 
    # Force evaluation of everything in the environment, so it will available on cluster
    .forceEval(ALL = TRUE)
    
    tmp <- .clusterSetUp(cluster = cluster, ncores = ncores, libraries = "synlik", exportALL = TRUE)
    cluster <- tmp$cluster
    ncores <- tmp$ncores
    clusterCreated <- tmp$clusterCreated
    registerDoSNOW(cluster)
    
    if( K %% ncores ) message(paste("Number of folds (", K, ") is not a multiple of ncores (", ncores, ").", sep = ''))
  }
  
  #  We simulate data
  datasets <- rlply(nrep, simulator(...))
    
  # Get cross-validated negative log-likelihood for each dataset
  withCallingHandlers({
    tmp <- llply(datasets, .selectDecay,  
                 # Extra args for .selectDecay
                 decay = decay, normalize = normalize, K = K, control = ctrl, 
                 multicore = multicore, ncores = ncores, cluster = cluster) 
  }, warning = function(w) {
    # There is a bug in plyr concerning a useless warning about "..."
    if (length(grep("... may be used in an incorrect context", conditionMessage(w))))
      invokeRestart("muffleWarning")
  })
  
  # Close the cluster if it was opened inside this function
  if(multicore && clusterCreated) stopCluster(cluster)
  
  negLogLik <- do.call("cbind", lapply(tmp, "[[", "negLogLik"))
    
  # Preparing output: returning a summary table of scores, all -log-lik and all normalizing constants
  out <- list()
  
  out$negLogLik <- do.call("cbind", lapply(tmp, "[[", "negLogLik"))
  colnames(out$negLogLik) <-  1:(K*nrep)
  
  out$summary <- rbind( decay, rowMeans(out$negLogLik), apply(out$negLogLik, 1, sd) )  
  rownames(out$summary) <- c("decay", "mean_score", "sd_score")
  
  out$normConst <- do.call("cbind", lapply(tmp, "[[", "normConst"))
  rownames(out$normConst) <- decay
  
  # (Optionally) Plot the score for each value in "decay".
  if(draw){
    if( normalize ) par(mfrow = c(2, 1))
    
    n <- length(decay)
    matplot(y = out$negLogLik, type = 'l', xaxt = "n", xlab = "Decay", ylab = "- Log-likelihood" )
    lines(out$summary[2, ], lwd = 2, col = 1)
    abline(v = (1:n)[ which.min(out$summary[2, ]) ], lty = 2, lwd = 2)
    points(out$summary[2, ], lwd = 3, col = 1)
    axis(1, at=1:n, labels = decay)
    
    if( normalize ){
      matplot(y = out$normConst, type = 'l', xaxt = "n", ylab = "Normalizing constants", xlab = "Decay" )
      lines(rowMeans(out$normConst), lwd = 2, col = 1)
      points(rowMeans(out$normConst), lwd = 3, col = 1)
      axis(1, at=1:n, labels = decay)
    }
  }
    
  return( invisible( out ) )
  
}



########
# Internal R function
########

.selectDecay <- function(X, decay, normalize, K, control, multicore = multicore, ncores = ncores, cluster = cluster)
{
  if( !is.matrix(X) ) X <- matrix(X, length(X), 1)
  
  n <- nrow(X)
  
  # Divide the sample in K folds
  folds <- mapply(function(a, b) rep(a, each = b), 1:K, c(rep(floor(n / K), K - 1), floor(n / K) + n %% K), SIMPLIFY = FALSE )  
  folds <- do.call("c", folds)
  
  ngrid <- length(decay)
  
  negLogLik <- matrix(NA, ngrid, K)
  normConst <- numeric(ngrid)
  rownames(negLogLik) <- decay
  colnames(negLogLik) <- 1:K
  
  if( control$nNorm ) sam <- rmvn(control$nNorm, colMeans(X), cov(X))
    
  # For each value of "decay" and for each fold, calculate the negative log-likelihood 
  # of the sample points belonging to that fold.
  for(ii in 1:ngrid)
  {
    message( paste("decay =", decay[ii]) )
    
    if( normalize ) {
      
      normConst[ ii ] <- mean( dsaddle(y = sam, X = X, decay = decay[ii], log = FALSE, fastInit = control$fastInit,
                                       normalize = FALSE, control = control,
                                       multicore = multicore, ncores = ncores, cluster = cluster)$llk / dmvn(sam, colMeans(X), cov(X)) )
      
    }
    
    negLogLik[ii, ] <- aaply(1:K, 
                             1,
                             function(input){
                               index <- which(folds == input)
                               -sum( dsaddle(X[index, , drop = F], X = X[-index, , drop = F], normalize = FALSE,
                                             decay = decay[ii], fastInit = control$fastInit, control = control, log = TRUE)$llk ) + 
                                             ifelse(normalize, length(index) * log(normConst[ ii ]), 0)
                             }, 
                             .progress = "text",
                             .parallel = multicore)
    
  }
  
  return( list( "negLogLik" = negLogLik, "normConst" = normConst ) )
  
}