#include "JavaTypeCacheReuseTestSupport.h"
#ifdef BENCH_USE_V2
#include "llvm/Analysis/Jeandle/CachedJavaTypeV2.h"
#endif
#include "llvm/IR/Verifier.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/FileSystem.h"
#include <chrono>
#include <cstdlib>
#include <sys/resource.h>
using namespace llvm;
using namespace llvm::jeandle;
using namespace llvm::jeandle::cache_reuse_test;
int main(int argc,char**argv){
 if(argc!=5)return 2;
 std::string scenario=argv[1],mode=argv[2];
 if(scenario!="cross-unique"&&scenario!="same"&&scenario!="cross"&&scenario!="same-edit"&&scenario!="other-edit")return 2;
 if(mode!="cached")return 2;
 auto batches=std::strtoull(argv[3],nullptr,10); bool diag=std::string(argv[4])=="diagnostic";
 if(!batches)return 2;
 VMEnvironment env; Fixture x(false,32,scenario=="cross-unique"?32:16);
 if(scenario=="other-edit")for(auto &bb:*x.F)if(bb.getName()=="fail")x.Noise=BinaryOperator::CreateAdd(x.F->getArg(1),ConstantInt::get(Type::getInt32Ty(x.C),1),"other.noise",bb.getTerminator()->getIterator());
 if(verifyModule(*x.M,&errs()))return 3;
 if(diag){std::error_code ec;raw_fd_ostream out(scenario+".ll",ec,sys::fs::OF_Text);if(ec)return 4;x.M->print(out,nullptr);}
 SMDiagnostic error; auto parsed=parseAssemblyFile(scenario+".ll",error,x.C);
 if(!parsed){error.print(argv[0],errs());return 7;}
 x.LVI.reset();x.AC.reset();x.M=std::move(parsed);x.F=x.M->getFunction("test");x.Obj=x.F->getArg(0);x.Contexts.clear();
 for(auto &bb:*x.F){
 if(bb.getName().starts_with("path") && std::stoi(bb.getName().drop_front(4).str())>=32)x.Contexts.push_back(bb.getTerminator());
 for(auto &i:bb)if(i.getName()==(scenario=="other-edit"?"other.noise":"unrelated"))x.Noise=cast<BinaryOperator>(&i);
 }
 x.DT.recalculate(*x.F);x.AC=std::make_unique<AssumptionCache>(*x.F);x.LVI=std::make_unique<LazyValueInfo>(x.AC.get(),&x.M->getDataLayout());
#ifdef BENCH_USE_V2
 JavaTypeCacheV2 cache(*x.F,JavaTypeCacheV2::Mode::StableOracleEpoch);
 cache.setStatsEnabled(diag);
#else
 JavaTypeCache cache;
 CachedJavaTypeQueryInfo info;
 uint64_t oldHits=0,oldFacts=0;
#endif
 uint64_t checksum=0,queries=0,oracle=0;
 rusage before{},after{};getrusage(RUSAGE_SELF,&before);auto start=std::chrono::steady_clock::now();
 for(uint64_t b=0;b<batches;++b){
#ifndef BENCH_REFERENCE
 cache.clear();
#endif
 x.LVI->clear();
 for(unsigned i=0;i<32;++i){
  if(i&&(scenario=="same-edit"||scenario=="other-edit")){
#ifndef BENCH_REFERENCE
   cache.invalidate({x.Noise});
#endif
   x.LVI->clear();x.Noise->setOperand(1,ConstantInt::get(Type::getInt32Ty(x.C),1+(i&1)));
  }
  auto *at=scenario=="cross-unique"?x.Contexts[i]:(scenario=="cross"?x.Contexts[i%16]:x.Contexts.front());
  LVINullEdgeOracle real{*x.LVI};
  auto callback=[&](Value*v,BasicBlock*f,BasicBlock*t){if(diag)++oracle;return real(v,f,t);};
#ifdef BENCH_USE_V2
  JavaType t=getCachedJavaTypeV2(x.Obj,&x.DT,at,callback,cache);
#elif defined(BENCH_REFERENCE)
  JavaType t=getJavaType(x.Obj,&x.DT,at,callback);
#else
  JavaType t=getCachedJavaType(x.Obj,&x.DT,at,callback,cache,info);
  if(diag){if(info.SkipVerification){errs()<<"verification truncated\n";return 8;}oldHits+=info.FinalHits;oldFacts+=info.FactsHits;}
#endif
  if(t.Klass!=22){errs()<<"wrong klass\n";return 5;}
  checksum+=t.Klass;++queries;
  if(diag){DominatorTree dt(*x.F);AssumptionCache ac(*x.F);LazyValueInfo lvi(&ac,&x.M->getDataLayout());LVINullEdgeOracle fresh{lvi};if(t!=getJavaType(x.Obj,&dt,at,fresh)){errs()<<"differential mismatch\n";return 6;}}
 }
 }
 getrusage(RUSAGE_SELF,&after);
 auto sec=[](timeval v){return v.tv_sec+v.tv_usec/1e6;};
#ifdef BENCH_USE_V2
 uint64_t hits=cache.Final.getStats().Hits,facts=cache.Facts.getStats().Hits;
#else
 uint64_t hits=oldHits,facts=oldFacts;
#endif
 json::Object out{{"scenario",scenario},{"mode",mode},{"queries",(int64_t)queries},{"checksum",(int64_t)checksum},{"cpu_s",sec(after.ru_utime)+sec(after.ru_stime)-sec(before.ru_utime)-sec(before.ru_stime)},{"wall_s",std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()},{"final_hits",(int64_t)hits},{"facts_hits",(int64_t)facts},{"oracle_calls",(int64_t)oracle}};
 outs()<<formatv("{0}\n",json::Value(std::move(out)));
}
