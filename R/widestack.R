
#' @importFrom utils head

record_stack <- function() {
  calls <- head(sys.calls(), -1)
  frames <- head(sys.frames(), -1)
  funcs <- lapply(seq_along(calls), sys.function)
  record_this_stack(calls, frames, funcs)
}

#' @importFrom utils tail

record_this_stack <- function(calls, frames, funcs) {
  frame_ids <- vcapply(frames, format.default)

  ## The async tasks currently initializing
  init_barriers <- find_calls_in_stack(calls, quote(async_def_init))
  init_defs <- lapply(frames[init_barriers], get_deferred_from_barrier)

  ## The async tasks currently running action or callback
  run_barriers  <- find_calls_in_stack(calls, quote(async_stack_run))
  run_defs  <- lapply(frames[run_barriers],  get_deferred_from_barrier)

  barriers <- init_barriers | run_barriers
  defs <- lapply(frames[barriers],  get_deferred_from_barrier)
  async_ids <- vcapply(defs, function(x) format.default(x$self))

  ## What to hide? From a hide barrier to the next barrier
  hide_barriers <- which(find_calls_in_stack(calls, quote(async_hide)))
  barrier_idx <- which(barriers)
  next_barriers <- viapply(
    hide_barriers,
    function(b) min(barrier_idx[barrier_idx > b] - 1L, length(calls))
  )
  to_hide <- logical(length(calls))
  for (i in seq_along(hide_barriers)) {
    to_hide[hide_barriers[i]:next_barriers[i]] <- TRUE
  }

  ## Also hide two calls before async_def_init
  to_hide[which(init_barriers) - 1] <- TRUE
  to_hide[which(init_barriers) - 2] <- TRUE

  ## Active async task, if any, either initializing or running
  last_async_frame <- tail(frames[barriers], 1)
  act_task <- if (length(last_async_frame)) last_async_frame[[1]]$deferred
  act_parent <- act_task$.__enclos_env__$private$parent
  act_id <- if (length(act_task)) format.default(act_task) else "main"
  act_parent_id <- if (length(act_parent)) format.default(act_parent) else NA_character_

  call_df <- list(
    task_id = c("main", async_ids)[cumsum(barriers) + 1],
    call = I(calls),
    frame_id = frame_ids,
    hide = to_hide,
    init = init_barriers,
    callback = run_barriers,
    envs = vcapply(funcs, function(x) environmentName(environment(x)))
  )

  ## Wide stacks of the prelude tasks, we need to make them unique. (TODO)
  ## Note that these are the start stacks only. Run stacks of a deferred
  ## might be included in another deferred's stack.
  pre <- c(defs, list(list(private = act_parent$.__enclos_env__$private)))
  pre_stacks <- drop_nulls(lapply(pre, function(x) x$private$start_stack))

  ## Merge the prelude to the current wide stack.
  ## `calls` is a named list of call stack data frames
  ## `parents` is a character vector
  extract_calls <- function(x) {
    unlist(lapply(x, "[[", "calls"), recursive = FALSE)
  }

  wsts <- list(
    calls = c(
      unique_names(extract_calls(pre_stacks)),
      structure(list(call_df), names = act_id)
    ),
    parents = unique_names(c(
      unlist(lapply(pre_stacks, "[[", "parents")),
      structure(act_parent_id, names = act_id)
    ))
  )

  structure(wsts, class = "async_wide_stack")
}

#' @importFrom utils capture.output

get_call_name <- function(call) {
  if (is.call(call)) {
    call[-1] <- NULL
    sub("[(][)]\\s*$", "", paste(capture.output(call), collapse = "\n"))
  } else {
    ## This should never happen, but better safe than sorry
    "<anonymous>"
  }
}

get_call_args <- function(call) {
  ## No arguments
  if (is.null(call[-1])) return("()")

  ## Otherwise format them
  call[[1]] <- as.symbol("foobar")
  str <- format(call)
  str[1] <- sub("^foobar", "", str[1])
  if (length(str) > 1) {
    str[-1] <- sub("^[ ]+", "", str[-1])
  }
  paste(str, collapse = "")
}

get_deferred_from_barrier <- function(frame) {
  list(
    self = frame$deferred,
    private = frame$deferred$.__enclos_env__$private
  )
}

print_wide_stack <- function(wst) {
  pr <- format_wide_stack(wst)
  cat(pr, sep = "\n")
}

format_wide_stack <- function(wst) {

  add_hash <- function(x) {
    x$same <- paste(
      x$frame_id,
      vcapply(lapply(x$call, format.default), paste, collapse = "\n")
    )
    x
  }
  stack <- lapply(wst$calls, add_hash)

  stack <- lapply(stack, as.data.frame, stringsAsFactors = FALSE)
  df <- do.call(rbind, stack)
  df <- df[ !duplicated(df$same), , drop = FALSE]

  df$fnams <- vcapply(df$call, get_call_name)
  df$fargs <- vcapply(df$call, get_call_args)

  df$out <- mapply(format_call, df$call, df$fnams, df$fargs, df$envs)

  ## Marks
  marks <- lapply(unique(df$task_id), function(t) {
    ifelse(df$task_id == t, "*", " ")
  })
  df$marks <- do.call(
    mapply,
    c(list(c), marks, USE.NAMES = FALSE, SIMPLIFY = FALSE)
  )

  pdf <- df[! df$hide, ]

  ## Lift init calls up one step to avoid duplication
  init_calls <- which(pdf$init) - 1L
  if (length(init_calls)) {
    pdf$out[init_calls] <- paste("+", pdf$out[init_calls])
  }

  compose <- function(x, y) ifelse(x == " " & y == " ", " ", "*")

  pdf$marks[init_calls] <- mapply(
    compose,
    pdf$marks[init_calls], pdf$marks[init_calls + 1], SIMPLIFY=FALSE
  )
  pdf <- pdf[! pdf$init, ]

  ## rewrite async_stack_run() calls to something more descriptive
  run_calls <- which(pdf$callback)
  if (length(run_calls)) {
    pdf$out[run_calls] <-
      paste(">", sub("^[+][ ]", "", pdf$out[run_calls - 1L]))
  }

  pdf <- unicode_wide_stack(pdf)

  pdf$mark <- vcapply(pdf$marks, paste, collapse = " ")
  pdf$mark <- add_arrows(pdf$mark)
  pdf$mark <- add_lines(pdf$mark)

  c(make_header(pdf), paste(pdf$mark, pdf$out))
}

add_arrows <- function(x) {
  w <- regexpr("(?<=[^ ])[ ]+(?=[^ ])", x, perl = TRUE)
  m <- regmatches(x, w)

  arrow <- if (has_utf8()) {
    make_unicode_arrow(nchar(m, type = "bytes"))
  } else {
    strrep("-", nchar(m))
  }

  regmatches(x, w) <- arrow
  x
}

add_lines <- function(x) {
  if (! has_utf8()) return(x)
  w <- regexpr("[ ]+$", x, perl = TRUE)
  light_grey <- crayon::make_style("#666666")
  regmatches(x, w) <- light_grey(strrep("\u2508", nchar(regmatches(x, w))))
  x
}

make_unicode_arrow <- function(l) {
  ifelse(l == 0, "", paste0(strrep("\u2508", l -1), "\u21e2"))
}

#' @importFrom utils getSrcDirectory getSrcFilename getSrcLocation

format_call <- function(call, fnam, fargs, env) {

  light_grey <- crayon::make_style("#666666")
  fargs <- if (nchar(fargs) > 50) {
    paste0(substring(fargs, 1, 50), cli::symbol$ellipsis)
  } else {
    fargs
  }
  fargs <- light_grey(fargs)
  env <- if (env %in% c("", "R_GlobalEnv")) "" else paste0(env, "::")
  env <- crayon::cyan(env)
  fnam <- crayon::yellow(fnam)

  out <- paste0(env, fnam, " ", fargs)

  dir <- getSrcDirectory(call)
  file <- getSrcFilename(call)
  line <- getSrcLocation(call)
  col <- getSrcLocation(call, which = "column")

  if (!is.null(line)) {
    loc <- crayon::green(paste0(
      "@ ", file.path(basename(dir), file), ":", line, ":", col
    ))
    out <- paste(out, loc)
  }

  out
}

make_header <- function(pdf) {
  num_tasks <- length(pdf$marks[[1]])
  header <- c(letters, LETTERS)
  num_tasks <- min(num_tasks, length(header))
  header <- paste(header[seq_len(num_tasks)], collapse = " ")

  style <- crayon::make_style("darkgrey", bg = TRUE)
  style(header)
}

unicode_wide_stack <- function(pdf) {
  ## Do we print unicode?
  if (! has_utf8()) return(pdf)

  ## Color and prettify markers
  pdf$marks <- get_mark_types(pdf)

  pdf$out <- sub("^[+] ", paste0(cli::symbol$star, " "), pdf$out)
  pdf$out <- sub("^[>] ", paste0("\u25b6", " "), pdf$out)

  pdf
}

get_mark_types <- function(pdf) {
  mx   <- "\u25aa"
  mx_  <- "\u25aa\u0329"
  m_x  <- "\u25ab\u030d"
  m_x_ <- "\u25ab\u0329\u030d"

  num_tasks <- length(pdf$marks[[1]])
  cols <- get_colors(num_tasks)
  styles <- lapply(cols, crayon::make_style)

  marks <- pdf$marks
  types <- marks
  for (i in seq_along(types)) {
    row <- marks[[i]]
    if (length(types) == 1) {
      types[[i]] <- sub("*", mx, row, fixed = TRUE)

    } else if (i == 1) {
      types[[i]] <- ifelse(
        marks[[i]] == " ", " ",
        ifelse(marks[[i + 1]] == "*", mx_, mx)
      )

    } else if (i == length(types)) {
      types[[i]] <- ifelse(
        marks[[i]] == " ", " ",
        ifelse(marks[[i - 1]] == "*", m_x, mx))

    } else {
      types[[i]] <- ifelse(
        marks[[i]] == " ", " ",
        ifelse(
          marks[[i - 1]] == "*",
          ifelse(marks[[i + 1]] == "*", m_x_, m_x),
          ifelse(marks[[i + 1]] == "*", mx_, mx)
        )
      )
    }
    types[[i]] <- vcapply(seq_along(types[[i]]), function(j) {
      if (types[[i]][j] == " ") " " else styles[[j]](types[[i]][j])
    })
  }

  types
}

#' @export

print.async_rejected <- function(x, ...) {
  print_wide_stack(x$call)
  invisible(x)
}

#' @export

format.async_rejected <- function(x, ...) {
  ## TODO
  format.default(x)
}

#' @export

conditionCall.async_rejected <- function(c) {
  tail(tail(c$call$calls, 1)[[1]]$call, 1)[[1]]
}

#' @export

conditionMessage.async_rejected <- function(c) {

  warn_if_debug_off <- function() {
    if (!isTRUE(getOption("async.debug"))) {
      paste0(
        "\n", "(Async debugging if off, turn it on with `",
        crayon::bold(crayon::italic("options(async.debug = TRUE)")), "`.)\n"
      )
    }
  }

  if (! inherits(c$call, "async_wide_stack")) {
    NextMethod()
  } else {
    crayon::reset(paste0(
      "\n\n",
      crayon::bold(crayon::red(cli::symbol$cross, c$message)), "\n",
      warn_if_debug_off(),
      paste(c("", format_wide_stack(c$call)), collapse = "\n")
    ))
  }
}
