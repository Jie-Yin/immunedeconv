#' Collection of deconvolution methods for mouse data.
#'
#' @import methods
#' @import dplyr
#' @importFrom testit assert
#' @import readr
#' @importFrom purrr map_dfr
#' @importFrom matrixStats rowSds
#' @import stringr
#' @import mMCPcounter
#' @import ComICS
#' @importFrom biomaRt useEnsembl getLDS
#' @importFrom tibble as_tibble
#' @importFrom rlang dots_list
#' @importFrom utils capture.output read.csv read.table tail write.table
#'
#' @name mouse_deconvolution
NULL


#' List of supported mouse deconvolution methods

#' The methods currently supported are
#' `mmcp_counter`, `seqimmucc`, `dcq`, `base`
#' The object is a named vector. The names correspond to the display name of the method,
#' the values to the internal name.
#'
#' @export
deconvolution_methods_mouse <- c(
  "mMCPcounter" = "mmcp_counter",
  "seqImmuCC" = "seqimmucc",
  "DCQ" = "dcq",
  "BASE" = "base"
)




############################################################################
# Deconvolution functions for consistently accessing each method
#
# These functions are called from the generic `deconvolute_mouse()` function.
# They can also be used by the end-user to access method-specific
# arguments.
############################################################################



#' Deconvolute using mMCP-counter
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples. Should be TPM normalized
#' @param log2 logical. If TRUE, log2 transforms the expression matrix
#' @param gene_id specifies the format of the gene IDs. Possible choices are 'Gene.Symbol'
#'    (default), 'ENSEMBL.ID' or 'Probes' (Affymetrix array probes)
#' @param genome specifies the mouse genome version to use, GCRm39 (default) or GCRm38
#' @export
#'
deconvolute_mmcp_counter <- function(gene_expression_matrix, log2 = TRUE,
                                     gene_id = "Gene.Symbol", genome = "GCRm39") {
  if (log2 == TRUE) {
    gene_expression_matrix <- log2(gene_expression_matrix + 1)
  }
  arguments <- dots_list(
    exp = gene_expression_matrix,
    features = gene_id,
    genomeVersion = genome
  )

  call <- rlang::call2(mMCPcounter::mMCPcounter.estimate, !!!arguments)
  results <- eval(call)
  results <- as.matrix(results)
  return(results)
}


#' Deconvolute using seqImmuCC
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples. Data
#'    should NOT be normalized (raw counts)
#' @param algorithm the method to use for deconvolution. Possible choices are
#'    'SVR' for CIBERSORT or 'LLSR' for least squares regression
#' @param ... passed through to original quantiseq method. A native argument takes precedence
#'   over an immunedeconv argument
#' @export
#'
deconvolute_seqimmucc <- function(gene_expression_matrix,
                                  algorithm = c("SVR", "LLSR"), ...) {
  signature.path <- system.file("extdata", "mouse_deconvolution", "sig_matr_seqImmuCC.txt",
    package = "immunedeconv", mustWork = TRUE
  )

  if (algorithm == "SVR") {
    assert("CIBERSORT.R is provided", exists("cibersort_binary", envir = config_env))
    source(get("cibersort_binary", envir = config_env))

    temp.expression.file <- tempfile()

    write_tsv(as_tibble(gene_expression_matrix, rownames = "gene_symbol"), path = temp.expression.file)
    perm <- 100
    # results = CIBERSORT(signature.path, temp.expression.file, perm, QN=FALSE, ...)
    # results = results %>%
    #  .[, !colnames(.) %in% c("RMSE", "P-value", "Correlation")]


    arguments <- dots_list(signature.path, temp.expression.file,
      perm = perm,
      QN = FALSE, ..., .homonyms = "last"
    )

    call <- rlang::call2(CIBERSORT, !!!arguments)
    results <- eval(call)
    results <- results %>%
      .[, !colnames(.) %in% c("RMSE", "P-value", "Correlation")]
  } else if (algorithm == "LLSR") {
    signature <- read.table(signature.path, header = T, sep = "\t", row.names = 1, check.names = F)
    results <- seqImmuCC_LLSR(signature, gene_expression_matrix, ...)
  }


  return(t(results))
}

#' Deconvolute using DCQ
#'
#'
#' Cell types obtained with this method can be further reduced with the
#'    map_result_to_celltypes function, using 'DCQ' as the method
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples
#' @param ref_samples a vector containing the names of the samples to be
#'    used to standardize the expressions. If NULL, all the samples are used.
#' @param n_repeats the number of models to generate. Predicted cell quantities
#'    will then be averaged.
#' @param combine_cells logical. This method estimates several cell types (~200).
#'    If TRUE (default), these are combined into 19 major immune-stromal cell types.
#' @param ... passed through to original quantiseq method. A native argument takes precedence
#'   over an immunedeconv argument
#' @export
#'
deconvolute_dcq <- function(gene_expression_matrix,
                            ref_samples = NULL, n_repeats = 10,
                            combine_cells = TRUE, ...) {
  # We need to scale the counts
  gene_expression_matrix <- as.matrix(gene_expression_matrix)

  if (is.null(ref_samples)) {
    rows.means <- rowMeans(gene_expression_matrix)
    rows.SD <- rowSds(gene_expression_matrix)
  } else {
    rows.means <- rowMeans(gene_expression_matrix[, ref_samples])
    rows.SD <- rowSds(gene_expression_matrix[, ref_samples])
  }
  rows.SD[rows.SD == 0] <- 1

  gene_expression_matrix <- (gene_expression_matrix - rows.means) / rows.SD

  arguments <- dots_list(
    reference_data = ComICS::immgen_dat,
    mix_data = gene_expression_matrix,
    marker_set = ComICS::DCQ_mar,
    number_of_repeats = n_repeats,
    ..., .homonyms = "last"
  )
  call <- rlang::call2(dcq, !!!arguments)
  results <- eval(call)
  results <- results$average

  if (combine_cells == TRUE) {
    results <- reduce_mouse_cell_types(results, "sum")
  }

  return(t(results))
}

#' Deconvolute using BASE
#'
#' Cell types obtained with this method can be further reduced with the
#'    map_result_to_celltypes function, using 'DCQ' as the method
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples. Data
#'    should be TPM normalized and log10 scaled.
#' @param n_permutations the number of permutations of each sample expression
#'    to generate. These are used to normalize the results.
#' @param log10 logical. if TRUE, log10 transforms the expression matrix.
#' @param combine_cells logical. This method estimates several cell types (~180).
#'    If TRUE (default), these are combined into 19 major immune-stromal cell types.
#' @export
deconvolute_base_algorithm <- function(gene_expression_matrix, n_permutations = 100,
                                       log10 = TRUE, combine_cells = TRUE) {
  base.compendium.path <- system.file("extdata", "mouse_deconvolution", "BASE_cell_compendium.rds",
    package = "immunedeconv", mustWork = TRUE
  )
  cell.compendium <- readRDS(base.compendium.path)

  results <- base_algorithm(gene_expression_matrix, cell.compendium, perm = n_permutations)

  if (combine_cells == TRUE) {
    results <- reduce_mouse_cell_types(results, "median")
  }

  return(t(results))
}



#' Perform deconvolution on a mouse RNAseq dataset
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples.
#'    Data should be TPM normalized, except when using seqImmuCC where raw
#'    counts are prefereable.
#' @param method string specifying the method
#' @param rmgenes noisy genes to be removed from the analysis
#' @param column Only relevant if `gene_expression` is an ExpressionSet. Defines in which column
#'   of fData the HGNC symbol can be found.
#' @param algorithm statistcal algorithm for SeqImmuCC (ignored by all other methods)
#' @param ... additional arguments passed to the respective method
#' @return a dataset with the estimated fractions/scores, with samples in rows and cell types in column
#'
#' @export
deconvolute_mouse <- function(gene_expression_matrix,
                              method = deconvolution_methods_mouse,
                              rmgenes = NULL, column = "gene_symbol",
                              algorithm = NULL, ...) {
  message(paste0("\n", ">>> Running ", method))


  if (!is.null(rmgenes)) {
    gene_expression_matrix <- gene_expression_matrix[!rownames(gene_expression_matrix) %in% rmgenes, ]
  }

  results <- switch(method,
    mmcp_counter = deconvolute_mmcp_counter(gene_expression_matrix, ...),
    seqimmucc = deconvolute_seqimmucc(gene_expression_matrix, algorithm, ...),
    dcq = deconvolute_dcq(gene_expression_matrix, ...),
    base = deconvolute_base_algorithm(gene_expression_matrix, ...)
  )

  results <- results %>%
    as_tibble(., rownames = "method_cell_type") %>%
    annotate_cell_type(method = method)

  return(results)
}


#' This function converts the mouse gene symbols into corresponding human ones, and vice versa.
#'
#' This function relies on the `biomaRt`` package and connects to the ENSEMBL repository
#'  to retrieve the gene symbols. If ENSEMBL cannot be reached, another solution will be
#'  used. Since it is memory intensive, users can choose not to run it.
#'
#' @param gene_expression_matrix a m x n matrix with m genes and n samples.
#'    Gene symbols must be the rownames of the matrix. If genes map to multiple gene symbols, the median
#'    expression will be returned.
#'    Can also be a m x 1 vector of the gene names. IN this case, only the converted genes will
#'    be returned.
#' @param mirror the ensembl mirror to use. Possible choices are 'www' (default),
#'    'uswest', 'useast', 'asia'
#' @param other_annot boolean, wether to run the alternative conversion method
#' @param convert_to one of 'human' or 'mouse'. Specifies the organism of the orthologs to look for
#' @return the same matrix, with the counts for the corresponding human genes.
#'    This matrix can directly be used with the immunedeconv methods. A message
#'    will display the ratio of original genes which were converted.
#'
#' @export
convert_human_mouse_genes <- function(gene_expression_matrix, mirror = "www",
                                      other_annot = TRUE, convert_to = c("human", "mouse")) {
  vect <- FALSE
  if (!is.vector(gene_expression_matrix)) {
    gene.names <- rownames(gene_expression_matrix)
    gene_expression_matrix <- as.data.frame(gene_expression_matrix)
    gene_expression_matrix$gene_name <- gene.names
  } else {
    gene_expression_matrix <- data.frame(
      "gene_name" = gene_expression_matrix,
      "X" = rep(0, length(gene_expression_matrix))
    )
    vect <- TRUE
  }

  genes.retrieved <- NULL
  tryCatch(
    expr = {
      human <- useEnsembl("ensembl", dataset = "hsapiens_gene_ensembl", mirror = mirror)
      mouse <- useEnsembl("ensembl", dataset = "mmusculus_gene_ensembl", mirror = mirror)

      if (convert_to == "human") {
        mart.use <- mouse
        mart.link <- human
        attr <- "mgi_symbol"
        attr.link <- "hgnc_symbol"
      } else {
        mart.use <- human
        mart.link <- mouse
        attr <- "hgnc_symbol"
        attr.link <- "mgi_symbol"
      }

      genes.retrieved <<- getLDS(
        attributes = c(attr),
        filters = attr, values = gene.names,
        mart = mart.use, attributesL = c(attr.link), martL = mart.link, uniqueRows = T
      )

      if (convert_to == "human") {
        newGenes.counts <<- gene_expression_matrix %>%
          left_join(., genes.retrieved, by = c("gene_name" = "MGI.symbol")) %>%
          select(., -c("gene_name")) %>%
          select(., c("HGNC.symbol", everything()))
      } else {
        newGenes.counts <<- gene_expression_matrix %>%
          left_join(., genes.retrieved, by = c("gene_name" = "HGNC.symbol")) %>%
          select(., -c("gene_name")) %>%
          select(., c("MGI.symbol", everything()))
      }
    },
    error = function(e) {
      if (other_annot) {
        print("Cannot connect to ENSEMBL. Using alternative method. This will take some time.")
        # Code adapted from: https://support.bioconductor.org/p/129636/#9144606

        mouse_human_genes <- read.csv("http://www.informatics.jax.org/downloads/reports/HOM_MouseHumanSequence.rpt", sep = "\t")

        find_corr_gene <- function(gene, mouse_human_genes_df, convert_to = c("human", "mouse")) {
          if (convert_to == "human") {
            orgn.name <- "mouse, laboratory"
            new.orgn <- "human"
          } else {
            orgn.name <- "human"
            new.orgn <- "mouse, laboratory"
          }

          class_key <- (mouse_human_genes_df %>%
            filter(Symbol == gene & Common.Organism.Name == orgn.name))[["DB.Class.Key"]]

          if (!identical(class_key, integer(0))) {
            output <- NULL
            new_genes <- (mouse_human_genes_df %>% filter(DB.Class.Key == class_key & Common.Organism.Name == new.orgn))[, "Symbol"]

            for (new_gene in new_genes) {
              output <- append(output, new_gene)
            }

            if (!is.null(output)) {
              return(data.frame(
                "new_gene" = output,
                "old_gene" = gene
              ))
            }
          }
        }

        genes.retrieved <- map_dfr(gene.names, function(x) find_corr_gene(x, mouse_human_genes, convert_to))

        newGenes.counts <<- gene_expression_matrix %>%
          left_join(., genes.retrieved, by = c("gene_name" = "old_gene")) %>%
          select(., -c("gene_name")) %>%
          select(., c("new_gene", everything()))
      }
    }
  )


  colnames(newGenes.counts)[1] <- "gene_name"
  newGenes.counts <- newGenes.counts[!(is.na(newGenes.counts$gene_name)), ] %>%
    group_by(gene_name) %>%
    summarise_all(median)

  newGenes.counts <- as.data.frame(newGenes.counts)

  rownames(newGenes.counts) <- newGenes.counts$gene_name
  newGenes.counts <- select(newGenes.counts, -c("gene_name"))

  fraction <- 100 * (nrow(newGenes.counts) / nrow(gene_expression_matrix)) %>%
    round(., 1)

  message(paste0("ATTENTION: Only the ", fraction, "% of genes was maintained"))

  if (!vect) {
    return(newGenes.counts)
  } else {
    return(rownames(newGenes.counts))
  }
}
