// cu2mini — C++ frontend (G2): CUDA subset -> MiniCUDA.json (schema minicuda/v1).
//
// Usage: cu2mini <in.cu> -o <out.json> [--cuda-path P] [--arch sm_XX]
// Exit: 0 ok | 2 unsupported input (envelope has program:null + diagnostics) | 3 internal error.
//
// Contract: schemas/minicuda-v1.schema.json. Rocq AST mirrors these shapes 1:1.

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "clang/AST/AST.h"
#include "clang/AST/Attr.h"
#include "clang/AST/Expr.h"
#include "clang/AST/Stmt.h"
#include "clang/ASTMatchers/ASTMatchers.h"
#include "clang/ASTMatchers/ASTMatchFinder.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/SourceLocation.h"
#include "clang/Frontend/FrontendAction.h"
#include "clang/Lex/Lexer.h"
#include "clang/Tooling/CompilationDatabase.h"
#include "clang/Tooling/Tooling.h"
#include "llvm/Support/raw_ostream.h"

using namespace clang;
using namespace clang::ast_matchers;
using namespace clang::tooling;

namespace {

std::string jsonEscape(const std::string &s) {
  std::string o;
  for (char c : s) {
    switch (c) {
    case '"': o += "\\\""; break;
    case '\\': o += "\\\\"; break;
    case '\n': o += "\\n"; break;
    case '\t': o += "\\t"; break;
    default: o += c;
    }
  }
  return o;
}

struct Diag {
  std::string feature, loc, hint;
};

struct Converter {
  ASTContext &ctx;
  std::vector<Diag> diags;
  bool ok = true;

  explicit Converter(ASTContext &c) : ctx(c) {}

  SourceManager &sm() { return ctx.getSourceManager(); }
  const LangOptions &langOpts() { return ctx.getLangOpts(); }

  std::string locStr(SourceLocation l) {
    FullSourceLoc fl(l, sm());
    auto exp = fl.getExpansionLoc();
    std::string f = sm().getFilename(exp).str();
    if (f.empty()) f = "<unknown>";
    return f + ":" + std::to_string(sm().getExpansionLineNumber(exp)) + ":" +
           std::to_string(sm().getExpansionColumnNumber(exp));
  }

  void reject(const Stmt *s, const std::string &feature, const std::string &hint) {
    ok = false;
    diags.push_back({feature, locStr(s->getBeginLoc()), hint});
  }

  // Strip semantically-neutral wrappers. Anything else implicit -> nullptr (reject).
  // NOTE (proof obligation for G3): 32-bit unsigned<->int IntegralCasts are
  // elided. Sound under the documented assumption that thread indices are
  // in-bounds (< 2^31), making the conversion the identity (see frontend README).
  const Expr *strip(const Expr *e) {
    while (true) {
      if (const auto *c = dyn_cast<ExprWithCleanups>(e)) { e = c->getSubExpr(); continue; }
      if (const auto *m = dyn_cast<MaterializeTemporaryExpr>(e)) { e = m->getSubExpr(); continue; }
      if (const auto *b = dyn_cast<CXXBindTemporaryExpr>(e)) { e = b->getSubExpr(); continue; }
      if (const auto *p = dyn_cast<ParenExpr>(e)) { e = p->getSubExpr(); continue; }
      if (const auto *ic = dyn_cast<ImplicitCastExpr>(e)) {
        switch (ic->getCastKind()) {
        case CK_LValueToRValue:
        case CK_FunctionToPointerDecay:
        case CK_BuiltinFnToFnPtr: // builtin callees (e.g. __syncthreads in device mode)
        case CK_ArrayToPointerDecay:
        case CK_NoOp:
        case CK_BitCast: // same-size device-pointer bitcasts are identity here; rejected elsewhere if lossy
          e = ic->getSubExpr();
          continue;
        case CK_IntegralCast: {
          QualType dst = ic->getType(), src = ic->getSubExpr()->getType();
          bool ok32 = (dst->isSpecificBuiltinType(BuiltinType::Int) ||
                       dst->isSpecificBuiltinType(BuiltinType::UInt)) &&
                      (src->isSpecificBuiltinType(BuiltinType::Int) ||
                       src->isSpecificBuiltinType(BuiltinType::UInt));
          if (ok32) {
            e = ic->getSubExpr();
            continue;
          }
          return nullptr;
        }
        default:
          return nullptr;
        }
      }
      return e;
    }
  }

  // Null-safe DeclRef recovery: NEVER dyn_cast a possibly-null strip()
  // result directly (asserts in debug, UB in release).
  static const DeclRefExpr *asDeclRef(const Expr *e) {
    if (!e) return nullptr;
    return dyn_cast<DeclRefExpr>(e);
  }

  // Clang models `blockIdx.x` etc. as PseudoObjectExpr around a
  // `.__fetch_builtin_{x,y,z}` member call. Recover "base.x" from that pattern.
  bool fetchBuiltin(const Stmt *s, std::string &out) {
    if (const auto *m = dyn_cast<MemberExpr>(s)) {
      std::string mem = m->getMemberDecl()->getNameAsString();
      const std::string pre = "__fetch_builtin_";
      if (mem.rfind(pre, 0) == 0) {
        const Expr *base = m->getBase();
        if (const auto *ov = dyn_cast<OpaqueValueExpr>(base))
          base = ov->getSourceExpr();
        if (const auto *dr = asDeclRef(strip(base))) {
          std::string b = dr->getDecl()->getNameAsString();
          if (b == "threadIdx" || b == "blockIdx" || b == "blockDim" || b == "gridDim") {
            out = b + "." + mem.substr(pre.size());
            return true;
          }
        }
      }
      return false;
    }
    for (const Stmt *c : s->children())
      if (c && fetchBuiltin(c, out)) return true;
    return false;
  }
  static bool isDim3(QualType t) {
    if (const CXXRecordDecl *rd = t->getAsCXXRecordDecl())
      return rd->getNameAsString() == "dim3";
    return false;
  }

  // Launch configs arrive as single-arg dim3 constructions around a scalar.
  // Unwrap dim3(x) only; multi-arg dim3 is rejected (schema holds scalars).
  // NOTE: dim3 layers are peeled BEFORE strip(), which would (correctly)
  // reject ConstructorConversion anywhere else.
  const Expr *unwrapConfig(const Expr *e) {
    while (true) {
      if (const auto *ic = dyn_cast<ImplicitCastExpr>(e)) {
        if (ic->getCastKind() == CK_ConstructorConversion && isDim3(ic->getType())) {
          e = ic->getSubExpr();
          continue;
        }
        break;
      }
      if (const auto *ce = dyn_cast<CXXConstructExpr>(e)) {
        // dim3(x) materializes defaulted y/z as CXXDefaultArgExpr children;
        // accept iff exactly one non-default argument is present.
        const Expr *real = nullptr;
        unsigned nReal = 0;
        for (unsigned i = 0; i < ce->getNumArgs(); ++i) {
          if (isa<CXXDefaultArgExpr>(ce->getArg(i))) continue;
          ++nReal;
          real = ce->getArg(i);
        }
        if (nReal == 1 && isDim3(ce->getType())) {
          e = real;
          continue;
        }
        return nullptr;
      }
      if (isa<CXXFunctionalCastExpr>(e) || isa<CStyleCastExpr>(e)) {
        const auto *c = cast<CastExpr>(e);
        if (isDim3(c->getType())) {
          e = c->getSubExpr();
          continue;
        }
        return nullptr;
      }
      break;
    }
    return strip(e);
  }

  bool isBuiltinBase(const Expr *base, std::string &name) {
    base = strip(base);
    if (const auto *d = dyn_cast<DeclRefExpr>(base)) {
      name = d->getDecl()->getNameAsString();
      return name == "threadIdx" || name == "blockIdx" || name == "blockDim" ||
             name == "gridDim";
    }
    return false;
  }

  // Returns "" on unsupported (caller emits diagnostic).
  std::string expr(const Expr *e) {
    e = strip(e);
    if (!e) return "";
    if (const auto *il = dyn_cast<IntegerLiteral>(e))
      return "{\"kind\": \"int\", \"value\": " + std::to_string(il->getValue().getSExtValue()) + "}";
    if (const auto *fl = dyn_cast<FloatingLiteral>(e)) {
      char buf[32];
      snprintf(buf, sizeof buf, "%.9g", fl->getValueAsApproximateDouble());
      return std::string("{\"kind\": \"float\", \"value\": ") + buf + "}";
    }
    if (const auto *dr = dyn_cast<DeclRefExpr>(e)) {
      if (isa<EnumConstantDecl>(dr->getDecl())) return ""; // memcpy-kind args handled at call site
      return "{\"kind\": \"var\", \"name\": \"" + jsonEscape(dr->getDecl()->getNameAsString()) + "\"}";
    }
    if (const auto *bo = dyn_cast<BinaryOperator>(e)) {
      if (bo->getOpcode() == BO_Assign || bo->isCompoundAssignmentOp()) return "";
      std::string l = expr(bo->getLHS()), r = expr(bo->getRHS());
      if (l.empty() || r.empty()) return "";
      return "{\"kind\": \"binop\", \"op\": \"" +
             std::string(BinaryOperator::getOpcodeStr(bo->getOpcode())) +
             "\", \"left\": " + l + ", \"right\": " + r + "}";
    }
    if (const auto *uo = dyn_cast<UnaryOperator>(e)) {
      if (uo->getOpcode() == UO_AddrOf) {
        if (const auto *dr = asDeclRef(strip(uo->getSubExpr())))
          return "{\"kind\": \"addrof\", \"name\": \"" +
                 jsonEscape(dr->getDecl()->getNameAsString()) + "\"}";
        return "";
      }
      if (uo->getOpcode() != UO_LNot && uo->getOpcode() != UO_Minus) return "";
      std::string s = expr(uo->getSubExpr());
      if (s.empty()) return "";
      return "{\"kind\": \"unop\", \"op\": \"" +
             std::string(UnaryOperator::getOpcodeStr(uo->getOpcode())) + "\", \"expr\": " + s + "}";
    }
    if (const auto *sub = dyn_cast<ArraySubscriptExpr>(e)) {
      std::string b = expr(sub->getBase()), i = expr(sub->getIdx());
      if (b.empty() || i.empty()) return "";
      return "{\"kind\": \"subscript\", \"base\": " + b + ", \"index\": " + i + "}";
    }
    if (const auto *m = dyn_cast<MemberExpr>(e)) {
      std::string base;
      if (isBuiltinBase(m->getBase(), base))
        return "{\"kind\": \"builtin\", \"name\": \"" + base + "." +
               m->getMemberDecl()->getNameAsString() + "\"}";
      std::string pseudo;
      if (fetchBuiltin(m, pseudo))
        return "{\"kind\": \"builtin\", \"name\": \"" + pseudo + "\"}";
      return "";
    }
    if (const auto *po = dyn_cast<PseudoObjectExpr>(e)) {
      std::string pseudo;
      if (fetchBuiltin(po, pseudo))
        return "{\"kind\": \"builtin\", \"name\": \"" + pseudo + "\"}";
      return "";
    }
    if (const auto *sz = dyn_cast<UnaryExprOrTypeTraitExpr>(e)) {
      // sizeof on v1 scalar types: fixed LP64 ABI sizes. Outsiders rejected.
      if (sz->getKind() == UETT_SizeOf && sz->isArgumentType()) {
        QualType t = sz->getArgumentType().getUnqualifiedType();
        if (t->isSpecificBuiltinType(BuiltinType::Float) ||
            t->isSpecificBuiltinType(BuiltinType::Int))
          return "{\"kind\": \"int\", \"value\": 4}";
        if (t->isSpecificBuiltinType(BuiltinType::Double))
          return "{\"kind\": \"int\", \"value\": 8}";
      }
      return "";
    }
    if (const auto *c = dyn_cast<CallExpr>(e)) {
      // Only atomicAdd may appear inside MiniCUDA expressions; every other
      // call (device helpers, warp collectives, ...) fails conversion here.
      // Warp collectives get their own diagnostic from the TU-wide warp
      // matcher; device-helper calls are diagnosed by callsDeviceFn checks.
      if (const auto *dr = asDeclRef(strip(c->getCallee()))) {
        if (dr->getDecl()->getNameAsString() == "atomicAdd") {
          std::string args;
          for (const Expr *a : c->arguments()) {
            std::string s = expr(a);
            if (s.empty()) return "";
            if (!args.empty()) args += ", ";
            args += s;
          }
          return "{\"kind\": \"call\", \"name\": \"atomicAdd\", \"args\": [" + args + "]}";
        }
      }
      return "";
    }
    return "";
  }

  static bool isWarpBuiltinName(const std::string &n) {
    return n == "__shfl_sync" || n == "__shfl_up_sync" || n == "__shfl_down_sync" ||
           n == "__shfl_xor_sync" || n == "__shfl" || n == "__ballot_sync" || n == "__ballot" ||
           n == "__any_sync" || n == "__all_sync" || n == "__activemask" ||
           n == "__match_any_sync" || n == "__match_all_sync";
  }

  // True if the subtree calls a __device__ helper (v1 reject with hint).
  static bool callsDeviceFn(const Stmt *s) {
    if (!s) return false;
    if (const auto *ce = dyn_cast<CallExpr>(s)) {
      if (const auto *dr = dyn_cast<DeclRefExpr>(ce->getCallee()->IgnoreParenImpCasts()))
        if (const auto *fd = dyn_cast<FunctionDecl>(dr->getDecl()))
          if (fd->hasAttr<CUDADeviceAttr>()) return true;
    }
    // Unwrap the CUDA builtin-accessor and cast sugar before recursing.
    if (const auto *po = dyn_cast<PseudoObjectExpr>(s)) {
      for (const Stmt *c : po->children())
        if (c && callsDeviceFn(c)) return true;
      return false;
    }
    if (const auto *ic = dyn_cast<ImplicitCastExpr>(s))
      return callsDeviceFn(ic->getSubExpr());
    if (const auto *cc = dyn_cast<CastExpr>(s))
      return callsDeviceFn(cc->getSubExpr());
    for (const Stmt *c : s->children())
      if (c && callsDeviceFn(c)) return true;
    return false;
  }

  // True if the subtree calls a warp-collective builtin (owned by the
  // TU-wide warp matcher; conversion sites skip silently to avoid duplicates).
  static bool callsWarpBuiltin(const Stmt *s) {
    if (!s) return false;
    if (const auto *ce = dyn_cast<CallExpr>(s)) {
      if (const auto *dr = dyn_cast<DeclRefExpr>(ce->getCallee()->IgnoreParenImpCasts()))
        if (isWarpBuiltinName(dr->getDecl()->getNameAsString())) return true;
    }
    for (const Stmt *c : s->children())
      if (c && callsWarpBuiltin(c)) return true;
    return false;
  }

  // Shared failure path for expression positions in kernel statements:
  // precise feature when recognizable, silent skip when a dedicated
  // TU-wide matcher owns the diagnostic (warp), generic reject otherwise.
  // Returns "" in all cases; sets ok=false unless skipped==true.
  std::string badKernelExpr(const Stmt *site, const Expr *e, const std::string &feature,
                            const std::string &hint, bool &skipped) {
    skipped = false;
    if (callsWarpBuiltin(e)) {
      skipped = true;
      return "";
    }
    if (callsDeviceFn(e)) {
      reject(site, "device-functions",
             "__device__ helpers are retargeted to v1.1 (schema v1 has no node); inline them for now");
      return "";
    }
    reject(site, feature, hint);
    return "";
  }

  std::string scalarName(QualType t, bool &isPtr) {
    t = t.getUnqualifiedType();
    isPtr = false;
    if (t->isPointerType()) {
      isPtr = true;
      t = t->getPointeeType().getUnqualifiedType();
    }
    if (const auto *bt = dyn_cast<BuiltinType>(t)) {
      switch (bt->getKind()) {
      case BuiltinType::Int: return "int";
      case BuiltinType::Float: return "float";
      case BuiltinType::Double: return "double";
      default: return "";
      }
    }
    return "";
  }

  // Convert one kernel-body statement. Returns "" if it splices to nothing (bare return/NullStmt).
  // Sets ok=false + diagnostic on unsupported.
  std::string kernelStmt(const Stmt *s) {
    s = stripStmt(s);
    if (!s) return "";
    if (isa<NullStmt>(s)) return "";
    if (isa<AsmStmt>(s)) return ""; // owned by the TU-wide asm matcher (single diagnostic per site)
    if (const auto *cs = dyn_cast<CompoundStmt>(s)) {
      std::string items;
      for (const Stmt *c : cs->body()) {
        std::string r = kernelStmt(c);
        if (!ok) return "";
        if (!r.empty()) {
          if (!items.empty()) items += ", ";
          items += r;
        }
      }
      return items; // spliced (caller wraps in array context)
    }
    if (const auto *ds = dyn_cast<DeclStmt>(s)) {
      if (!ds->isSingleDecl()) { reject(s, "multi-decl", "split into single declarations"); return ""; }
      // __shared__ declarations are collected by kernelDecl; skip here.
      if (const auto *vd0 = dyn_cast<VarDecl>(ds->getSingleDecl()))
        if (vd0->hasAttr<CUDASharedAttr>()) return "";
      const auto *vd = dyn_cast<VarDecl>(ds->getSingleDecl());
      bool isPtr = false;
      std::string tn = vd ? scalarName(vd->getType(), isPtr) : "";
      if (!vd || tn.empty() || isPtr || !vd->hasInit()) {
        reject(s, vd && vd->hasInit() ? "bad-type" : "uninitialized",
               "kernel locals must be initialized scalars of type int/float/double");
        return "";
      }
      std::string v = expr(vd->getInit());
      if (v.empty()) {
        bool skipped = false;
        badKernelExpr(s, vd->getInit(), "bad-init", "initializer uses unsupported expressions", skipped);
        return "";
      }
      return "{\"kind\": \"let\", \"name\": \"" + jsonEscape(vd->getNameAsString()) +
             "\", \"type\": \"" + tn + "\", \"value\": " + v + "}";
    }
    if (const auto *bo = dyn_cast<BinaryOperator>(s)) {
      if (bo->getOpcode() == BO_Assign) {
        std::string t = expr(bo->getLHS()), v = expr(bo->getRHS());
        if (t.empty() || v.empty()) {
          bool skipped = false;
          badKernelExpr(s, t.empty() ? bo->getLHS() : bo->getRHS(), "bad-assign",
                        "assignment uses unsupported expressions", skipped);
          return "";
        }
        return "{\"kind\": \"store\", \"target\": " + t + ", \"value\": " + v + "}";
      }
      reject(s, "compound-assign", "rewrite as a plain assignment");
      return "";
    }
    if (const auto *is = dyn_cast<IfStmt>(s)) {
      std::string c = expr(is->getCond());
      if (c.empty()) {
        bool skipped = false;
        badKernelExpr(s, is->getCond(), "bad-cond", "if condition uses unsupported expressions", skipped);
        return "";
      }
      std::string t = stmtList(is->getThen()), e;
      if (!ok) return "";
      if (is->getElse()) { e = stmtList(is->getElse()); if (!ok) return ""; }
      return "{\"kind\": \"if\", \"cond\": " + c + ", \"then\": [" + t + "], \"else\": [" + e + "]}";
    }
    if (const auto *ce = dyn_cast<CallExpr>(s)) {
      if (const auto *dr = asDeclRef(strip(ce->getCallee()))) {
        std::string n = dr->getDecl()->getNameAsString();
        if (n == "__syncthreads" && ce->getNumArgs() == 0) return "{\"kind\": \"syncthreads\"}";
        if (n == "atomicAdd") {
          std::string args;
          for (const Expr *a : ce->arguments()) {
            std::string x = expr(a);
            if (x.empty()) { reject(s, "bad-atomic", "atomicAdd uses unsupported arguments"); return ""; }
            if (!args.empty()) args += ", ";
            args += x;
          }
          return "{\"kind\": \"expr_stmt\", \"expr\": {\"kind\": \"call\", \"name\": \"atomicAdd\", \"args\": [" + args + "]}}";
        }
      }
      if (callsWarpBuiltin(ce)) return ""; // owned by the TU-wide warp matcher
      if (callsDeviceFn(ce)) {
        reject(s, "device-functions",
               "__device__ helpers are retargeted to v1.1 (schema v1 has no node); inline them for now");
        return "";
      }
      reject(s, "device-call", "only __syncthreads() and atomicAdd() calls are supported in kernels");
      return "";
    }
    if (isa<CUDAKernelCallExpr>(s)) { reject(s, "nested-launch", "kernel launches are host-only"); return ""; }
    if (const auto *rs = dyn_cast<ReturnStmt>(s)) {
      if (rs->getRetValue()) { reject(s, "valued-return", "kernels return void"); return ""; }
      return "";
    }
    if (isa<ForStmt>(s) || isa<WhileStmt>(s) || isa<DoStmt>(s)) {
      reject(s, "loops", "v1 MiniCUDA has no kernel loops; restructure to flat thread-indexed code");
      return "";
    }
    if (isa<SwitchStmt>(s) || isa<BreakStmt>(s) || isa<ContinueStmt>(s) || isa<GotoStmt>(s) || isa<LabelStmt>(s)) {
      reject(s, "control-flow", "only if-statements are supported in v1 kernels");
      return "";
    }
    reject(s, "stmt", "unsupported statement in kernel body");
    return "";
  }

  const Stmt *stripStmt(const Stmt *s) {
    while (const auto *e = dyn_cast<Expr>(s)) {
      const Expr *u = strip(e);
      if (u == e) return s;
      s = u;
    }
    return s;
  }

  std::string stmtList(const Stmt *s) {
    s = stripStmt(s);
    std::string out;
    if (const auto *cs = dyn_cast<CompoundStmt>(s)) {
      for (const Stmt *c : cs->body()) {
        std::string r = kernelStmt(c);
        if (!ok) return "";
        if (!r.empty()) {
          if (!out.empty()) out += ", ";
          out += r;
        }
      }
      return out;
    }
    std::string r = kernelStmt(s);
    return ok ? r : "";
  }

  // Substrings that must never survive into host_code passthrough: any of
  // these implies out-of-scope APIs whose names the printer would otherwise
  // emit verbatim and unmapped (silent miscompile). Checked case-sensitively;
  // v1 favors fail-closed over comment-text false positives (documented).
  bool hostLeak(const std::string &text) {
    static const char *k[] = {"cuda", "cublas", "cusparse", "cufft", "curand",
                              "cusolver", "cudnn", "thrust::", "thrust/", "<thrust",
                              "cooperative_groups", "nccl", "NCCL", nullptr};
    for (const char **p = k; *p; ++p)
      if (text.find(*p) != std::string::npos) return true;
    return false;
  }

  std::string sourceText(const Stmt *s) {
    SourceLocation b = s->getBeginLoc();
    SourceLocation e = Lexer::getLocForEndOfToken(s->getEndLoc(), 0, sm(), langOpts());
    // Token ranges exclude a statement's terminating ';' although it is
    // present in source (e.g. inner `++bad;` of a for-body). Swallow one
    // following semicolon so host_code reprints verbatim-compilable.
    Token tok;
    if (!Lexer::getRawToken(e, tok, sm(), langOpts()) && tok.is(tok::semi))
      e = e.getLocWithOffset(tok.getLength());
    return Lexer::getSourceText(CharSourceRange::getCharRange(b, e), sm(), langOpts()).str();
  }

  // ---- host side ----
  std::string kernelDecl(const FunctionDecl *fd, std::string &out) {
    std::string params;
    for (const ParmVarDecl *p : fd->parameters()) {
      bool isPtr = false;
      std::string tn = scalarName(p->getType(), isPtr);
      if (tn.empty()) { reject(fd->getBody(), "bad-param", "kernel params must be int/float/double or pointers thereto"); return ""; }
      if (!params.empty()) params += ", ";
      params += "{\"name\": \"" + jsonEscape(p->getNameAsString()) + "\", \"type\": \"" + tn +
                "\", \"pointer\": " + (isPtr ? "true" : "false") + "}";
    }
    // __shared__ declarations: collected into the kernel's shared list
    // (constant-size scalar arrays only). NOTE: kernels declaring shared
    // state transpile but fall OUTSIDE the proved fragment (WellSync
    // requires shared=[]); see SUPPORTED.md and rocq/README.md.
    std::string shared;
    if (const auto *body = dyn_cast<CompoundStmt>(fd->getBody())) {
      for (const Stmt *c : body->body()) {
        const auto *ds = dyn_cast<DeclStmt>(c);
        if (!ds || !ds->isSingleDecl()) continue;
        const auto *vd = dyn_cast<VarDecl>(ds->getSingleDecl());
        if (!vd || !vd->hasAttr<CUDASharedAttr>()) continue;
        const auto *arr = dyn_cast<ConstantArrayType>(vd->getType());
        bool isPtr = false;
        std::string tn = arr ? scalarName(arr->getElementType(), isPtr) : "";
        long long sz = arr ? arr->getSize().getSExtValue() : 0;
        if (tn.empty() || isPtr || sz <= 0) {
          reject(c, "shared-mem",
                 "__shared__ must be a constant-size scalar array (int/float/double, size >= 1)");
          return "";
        }
        if (!shared.empty()) shared += ", ";
        shared += "{\"name\": \"" + jsonEscape(vd->getNameAsString()) + "\", \"type\": \"" + tn +
                  "\", \"size\": " + std::to_string(sz) + "}";
      }
      if (!ok) return "";
    }
    std::string body = stmtList(fd->getBody());
    if (!ok) return "";
    out = "{\"kind\": \"kernel\", \"name\": \"" + jsonEscape(fd->getNameAsString()) +
          "\", \"qualifier\": \"__global__\", \"params\": [" + params +
          "], \"shared\": [" + shared + "], \"body\": [" + body + "]}";
    return out;
  }

  bool isCudaApi(const std::string &n) {
    static const char *k[] = {"cudaMalloc", "cudaMemcpy", "cudaMemset", "cudaFree", "cudaStreamCreate",
                              "cudaStreamSynchronize", "cudaStreamDestroy", "cudaEventCreate", "cudaEventRecord",
                              "cudaEventSynchronize", "cudaEventDestroy", "cudaEventElapsedTime", "cudaGetLastError",
                              "cudaGetErrorString", "cudaSetDevice", "cudaDeviceSynchronize", nullptr};
    for (const char **p = k; *p; ++p)
      if (n == *p) return true;
    return false;
  }

  // Convert one top-level host statement -> api/launch node, else host_code passthrough.
  std::string hostStmt(const Stmt *s) {
    s = stripStmt(s);
    if (!s || isa<NullStmt>(s)) return "";
    if (const auto *cs = dyn_cast<CompoundStmt>(s)) {
      std::string items;
      for (const Stmt *c : cs->body()) {
        std::string r = hostStmt(c);
        if (!ok) return "";
        if (!r.empty()) {
          if (!items.empty()) items += ", ";
          items += r;
        }
      }
      return items;
    }
    if (const auto *ds = dyn_cast<DeclStmt>(s))
      return hostCode(s); // declarations pass through opaquely
    const Expr *e = dyn_cast<Expr>(s);
    if (!e) return hostCode(s);
    e = strip(e);
    if (const auto *kl = dyn_cast<CUDAKernelCallExpr>(e)) {
      const auto *dr = asDeclRef(strip(kl->getCallee()));
      if (!dr) { reject(s, "bad-launch", "launch callee must name a kernel"); return ""; }
      const CallExpr *cfg = kl->getConfig();
      if (!cfg || cfg->getNumArgs() < 2) { reject(s, "bad-launch", "launch needs grid and block"); return ""; }
      const Expr *ge = unwrapConfig(cfg->getArg(0)), *be = unwrapConfig(cfg->getArg(1));
      std::string g = ge ? expr(ge) : "", b = be ? expr(be) : "";
      if (g.empty() || b.empty()) { reject(s, "dim3-config", "v1 launch configs must be scalar integer expressions (no dim3)"); return ""; }
      std::string stream = "null";
      if (cfg->getNumArgs() >= 4 && !isa<CXXDefaultArgExpr>(cfg->getArg(3)) &&
          !isa<GNUNullExpr>(cfg->getArg(3))) {
        const Expr *se = strip(cfg->getArg(3));
        if (const auto *sd = dyn_cast<DeclRefExpr>(se))
          stream = "\"" + jsonEscape(sd->getDecl()->getNameAsString()) + "\"";
        else { reject(s, "bad-stream", "launch stream must be a stream variable"); return ""; }
      }
      std::string args;
      for (const Expr *a : kl->arguments()) {
        std::string x = expr(a);
        if (x.empty()) { reject(s, "bad-launch-arg", "launch argument uses unsupported expressions"); return ""; }
        if (!args.empty()) args += ", ";
        args += x;
      }
      return "{\"kind\": \"launch\", \"kernel\": \"" + jsonEscape(dr->getDecl()->getNameAsString()) +
             "\", \"grid\": " + g + ", \"block\": " + b + ", \"stream\": " + stream +
             ", \"args\": [" + args + "]}";
    }
    if (const auto *ce = dyn_cast<CallExpr>(e)) {
      if (const auto *dr = asDeclRef(strip(ce->getCallee()))) {
        std::string n = dr->getDecl()->getNameAsString();
        if (isCudaApi(n)) {
          std::string args, copyKind;
          unsigned skip = 0;
          if (n == "cudaMemcpy" && ce->getNumArgs() == 4) {
            const Expr *k = strip(ce->getArg(3));
            if (const auto *kd = dyn_cast<DeclRefExpr>(k)) {
              std::string kn = kd->getDecl()->getNameAsString();
              const std::string pre = "cudaMemcpy";
              if (kn.rfind(pre, 0) != 0) { reject(s, "bad-copykind", "memcpy kind must be a cudaMemcpy* enum"); return ""; }
              copyKind = kn.substr(pre.size());
            } else { reject(s, "bad-copykind", "memcpy kind must be a cudaMemcpy* enum"); return ""; }
            skip = 1;
          }
          for (unsigned i = 0; i + skip < ce->getNumArgs(); ++i) {
            std::string x = expr(ce->getArg(i));
            if (x.empty()) { reject(s, "bad-api-arg", std::string("unsupported argument to ") + n); return ""; }
            if (!args.empty()) args += ", ";
            args += x;
          }
          std::string node = "{\"kind\": \"api\", \"name\": \"" + n + "\", \"args\": [" + args + "]";
          if (!copyKind.empty()) node += ", \"copyKind\": \"" + copyKind + "\"";
          return node + "}";
        }
      }
    }
    return hostCode(s);
  }

  std::string hostCode(const Stmt *s) {
    std::string t = sourceText(s);
    if (hostLeak(t)) {
      reject(s, "host-cuda-leak",
             "host code mentions out-of-scope CUDA-ecosystem APIs; port or remove it (see SUPPORTED.md)");
      return "";
    }
    return "{\"kind\": \"host_code\", \"text\": \"" + jsonEscape(t) + "\", \"loc\": \"" +
           locStr(s->getBeginLoc()) + "\"}";
  }
};

struct Finder : MatchFinder::MatchCallback {
  Converter &cv;
  std::string kernels; // JSON array items (comma-joined)
  explicit Finder(Converter &c) : cv(c) {}
  void run(const MatchFinder::MatchResult &r) override {
    const auto *fd = r.Nodes.getNodeAs<FunctionDecl>("kernel");
    if (!fd || !fd->hasBody()) return;
    if (!cv.sm().isInMainFile(fd->getLocation())) return;
    std::string k;
    cv.kernelDecl(fd, k);
    if (!cv.ok) return;
    if (!kernels.empty()) kernels += ", ";
    kernels += k;
  }
};

struct WarpFinder : MatchFinder::MatchCallback {
  Converter &cv;
  explicit WarpFinder(Converter &c) : cv(c) {}
  void run(const MatchFinder::MatchResult &r) override {
    const auto *s = r.Nodes.getNodeAs<CallExpr>("warp");
    if (!s || !cv.sm().isInMainFile(s->getBeginLoc())) return;
    cv.reject(s, "warp-collective",
              "warp-collective builtins are out of scope for v1 (wavefront sizes differ on AMD); restructure to block-scoped code");
  }
};
struct AsmFinder : MatchFinder::MatchCallback {
  Converter &cv;
  explicit AsmFinder(Converter &c) : cv(c) {}
  void run(const MatchFinder::MatchResult &r) override {
    const auto *s = r.Nodes.getNodeAs<Stmt>("asm");
    if (!s || !isa<AsmStmt>(s) || !cv.sm().isInMainFile(s->getBeginLoc())) return;
    cv.reject(s, "inline-asm",
              "inline PTX asm is out of scope for v1 (see SUPPORTED.md); lift to portable HIP or await the v2 asm-lifter");
  }
};

class Action : public ASTFrontendAction {
public:
  struct Results {
    std::string kernels, host;
    std::vector<Diag> diags;
    bool tuOk = true;
    // Non-CUDA #includes, captured textually in main() (preprocessor-level,
    // invisible to matchers), prepended as host_code nodes. cuda_runtime.h
    // is mapped to the HIP header instead; other cuda* headers are
    // rejected via preDiags (imply out-of-scope APIs).
    std::vector<std::pair<std::string, std::string>> incs; // (text, loc)
    std::vector<Diag> preDiags;
  };
  Results &res;

  explicit Action(Results &r) : res(r) {}

  std::unique_ptr<ASTConsumer> CreateASTConsumer(CompilerInstance &, StringRef) override {
    return std::make_unique<Consumer>(res);
  }

  struct Consumer : ASTConsumer {
    Results &res;
    MatchFinder finder;
    std::unique_ptr<Converter> cv;
    std::unique_ptr<Finder> kf;
    std::unique_ptr<AsmFinder> af;
    std::unique_ptr<WarpFinder> wf;
    explicit Consumer(Results &r) : res(r) {}
    void HandleTranslationUnit(ASTContext &ctx) override {
      cv = std::make_unique<Converter>(ctx);
      kf = std::make_unique<Finder>(*cv);
      af = std::make_unique<AsmFinder>(*cv);
      wf = std::make_unique<WarpFinder>(*cv);
      finder.addMatcher(functionDecl(hasAttr(attr::CUDAGlobal), isDefinition()).bind("kernel"),
                        kf.get());
      finder.addMatcher(stmt().bind("asm"), af.get());
      finder.addMatcher(
          callExpr(callee(functionDecl(matchesName("__shfl.*|__ballot.*|__any_sync|__all_sync|"
                                                   "__activemask|__match_.*"))))
              .bind("warp"),
          wf.get());
      finder.matchAST(ctx);
      if (!cv->ok) {
        res.tuOk = false;
        res.diags = cv->diags;
        return;
      }
      // Host walk: every in-main-file function that is neither kernel nor device fn.
      std::string items;
      for (Decl *d : ctx.getTranslationUnitDecl()->decls()) {
        const auto *fd = dyn_cast<FunctionDecl>(d);
        if (!fd || !fd->hasBody()) continue;
        if (!ctx.getSourceManager().isInMainFile(fd->getLocation())) continue;
        if (fd->hasAttr<CUDAGlobalAttr>()) continue; // already converted
        if (fd->hasAttr<CUDADeviceAttr>()) {
          cv->reject(fd->getBody(), "device-functions",
                     "__device__ helpers are retargeted to v1.1 (schema v1 has no node); inline them for now");
          res.tuOk = false;
          res.diags = cv->diags;
          return;
        }
        std::string r = cv->hostStmt(fd->getBody());
        if (!cv->ok) {
          res.tuOk = false;
          res.diags = cv->diags;
          return;
        }
        if (!r.empty()) {
          if (!items.empty()) items += ", ";
          items += r;
        }
      }
      res.kernels = kf->kernels;
      // Prepend textual #includes (captured in main) ahead of walked nodes.
      std::string prefix;
      for (const auto &inc : res.incs) {
        if (!prefix.empty()) prefix += ", ";
        prefix += "{\"kind\": \"host_code\", \"text\": \"" + jsonEscape(inc.first) +
                  "\", \"loc\": \"" + jsonEscape(inc.second) + "\"}";
      }
      res.host = prefix + ((prefix.empty() || items.empty()) ? "" : ", ") + items;
      res.diags = cv->diags;
    }
  };
};

struct ActionFactory : FrontendActionFactory {
  Action::Results &res;
  explicit ActionFactory(Action::Results &r) : res(r) {}
  std::unique_ptr<FrontendAction> create() override { return std::make_unique<Action>(res); }
};

} // namespace

int main(int argc, const char **argv) {
  if (argc < 4) {
    llvm::errs() << "usage: cu2mini <in.cu> -o <out.json> [--cuda-path P] [--arch sm_XX] [--resource-dir D]\n";
    return 3;
  }
  std::string in, out, cudaPath = "/opt/cuda", arch = "sm_86",
                resourceDir = "/usr/lib/clang/22";
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "-o" && i + 1 < argc) out = argv[++i];
    else if (a == "--cuda-path" && i + 1 < argc) cudaPath = argv[++i];
    else if (a == "--arch" && i + 1 < argc) arch = argv[++i];
    else if (a == "--resource-dir" && i + 1 < argc) resourceDir = argv[++i];
    else if (!a.empty() && a[0] != '-') in = a;
    else {
      llvm::errs() << "unknown arg: " << a << "\n";
      return 3;
    }
  }
  if (in.empty() || out.empty()) {
    llvm::errs() << "usage: cu2mini <in.cu> -o <out.json> [--cuda-path P] [--arch sm_XX] [--resource-dir D]\n";
    return 3;
  }
  std::vector<std::string> args = {"-std=c++17",
                                   "-resource-dir=" + resourceDir,
                                   "--cuda-path=" + cudaPath,
                                   "--cuda-device-only",
                                   "--cuda-gpu-arch=" + arch,
                                   "-I" + cudaPath + "/include"};
  FixedCompilationDatabase cdb(".", args);
  ClangTool tool(cdb, {in});
  Action::Results res;
  // Textual #include scan (preprocessor-level, invisible to matchers).
  // cuda_runtime.h is mapped to the HIP header; other cuda* headers imply
  // out-of-scope APIs and are rejected; the rest become host_code nodes.
  {
    FILE *sf = fopen(in.c_str(), "r");
    if (!sf) {
      llvm::errs() << "cu2mini: cannot open " << in << "\n";
      return 3;
    }
    char line[4096];
    int lineno = 0;
    while (fgets(line, sizeof line, sf)) {
      ++lineno;
      std::string ln = line;
      while (!ln.empty() && (ln.back() == '\n' || ln.back() == '\r')) ln.pop_back();
      size_t p = ln.find_first_not_of(" \t");
      if (p == std::string::npos || ln.compare(p, 8, "#include") != 0) continue;
      std::string loc = in + ":" + std::to_string(lineno) + ":1";
      if (ln.find("cuda_runtime.h") != std::string::npos) continue;
      // Reuse the host-leak vocabulary: any CUDA-ecosystem header implies
      // out-of-scope APIs (cublas/cudnn/thrust/... contain no "cuda").
      std::string hdr = ln;
      auto isEcosystem = [&]() {
        static const char *k[] = {"cuda", "CUDA", "cublas", "cusparse", "cufft", "curand",
                                  "cusolver", "cudnn", "thrust", "nccl", "NCCL", nullptr};
        for (const char **p = k; *p; ++p)
          if (hdr.find(*p) != std::string::npos) return true;
        return false;
      };
      if (isEcosystem()) {
        res.preDiags.push_back({"unsupported-include", loc,
                                "non-runtime CUDA-ecosystem headers imply out-of-scope APIs (see SUPPORTED.md)"});
      } else {
        res.incs.emplace_back(ln.substr(p), loc);
      }
    }
    fclose(sf);
    res.incs.shrink_to_fit();
  }
  ActionFactory factory(res);
  int rc = tool.run(&factory);
  if (rc != 0) {
    llvm::errs() << "cu2mini: ClangTool failed (rc=" << rc << ")\n";
    return 3;
  }
  FILE *f = fopen(out.c_str(), "w");
  if (!f) {
    llvm::errs() << "cu2mini: cannot open " << out << "\n";
    return 3;
  }
  std::string body;
  bool blocked = !res.tuOk || !res.preDiags.empty();
  if (!blocked)
    body = "\"program\": {\"header\": \"cuda_runtime.h\", \"kernels\": [" + res.kernels +
           "], \"host\": [" + res.host + "]}";
  else
    body = "\"program\": null";
  std::string dj;
  for (const Diag &d : res.preDiags) {
    if (!dj.empty()) dj += ", ";
    dj += "{\"code\": \"Unsupported\", \"feature\": \"" + jsonEscape(d.feature) + "\", \"loc\": \"" +
          jsonEscape(d.loc) + "\", \"hint\": \"" + jsonEscape(d.hint) + "\"}";
  }
  for (const Diag &d : res.diags) {
    if (!dj.empty()) dj += ", ";
    dj += "{\"code\": \"Unsupported\", \"feature\": \"" + jsonEscape(d.feature) + "\", \"loc\": \"" +
          jsonEscape(d.loc) + "\", \"hint\": \"" + jsonEscape(d.hint) + "\"}";
  }
  fprintf(f, "{\n  \"schema\": \"minicuda/v1\",\n  \"source\": \"%s\",\n  %s,\n  \"diagnostics\": [%s]\n}\n",
          jsonEscape(in).c_str(), body.c_str(), dj.c_str());
  fclose(f);
  if (blocked) {
    for (const Diag &d : res.preDiags)
      llvm::errs() << in << ": Unsupported[" << d.feature << "] at " << d.loc << ": " << d.hint << "\n";
    for (const Diag &d : res.diags)
      llvm::errs() << in << ": Unsupported[" << d.feature << "] at " << d.loc << ": " << d.hint << "\n";
    return 2;
  }
  return 0;
}
