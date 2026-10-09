/* Add the three narrow rules graphics clients need to share memfd-backed buffers
 * (each one matches a denial seen in the guest log).
 * Does not change permissive domains, policy capabilities, MLS or constraints.
 */
#include <stdio.h>
#include <stdlib.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/hashtab.h>
#include <sepol/policydb/avtab.h>
int main(int argc,char **argv) {
 if(argc!=3)return 2;
 policydb_t p;policy_file_t f;policydb_init(&p);policy_file_init(&f);
 f.type=PF_USE_STDIO;f.fp=fopen(argv[1],"rb");if(!f.fp)return 3;
 if(policydb_read(&p,&f,0))return 4;fclose(f.fp);
 type_datum_t *target=hashtab_search(p.p_types.table,"hal_graphics_allocator_default");
 class_datum_t *c=hashtab_search(p.p_classes.table,"memfd_file");if(!target||!c)return 5;
 const char *perms[]={"read","write","map","getattr"};unsigned bits=0;
 for(unsigned i=0;i<4;i++) {
  perm_datum_t *v=hashtab_search(c->permissions.table,perms[i]);
  if(!v&&c->comdatum)v=hashtab_search(c->comdatum->permissions.table,perms[i]);
  if(!v||!v->s.value||v->s.value>32)return 6;bits|=1U<<(v->s.value-1);
 }
 const char *sources[]={"platform_app","priv_app","priv_app_36"};
 for(unsigned i=0;i<3;i++) {
  type_datum_t *source=hashtab_search(p.p_types.table,sources[i]);if(!source)return 7;
  avtab_key_t key={.source_type=source->s.value,.target_type=target->s.value,.target_class=c->s.value,.specified=AVTAB_ALLOWED};
  avtab_datum_t *old=avtab_search(&p.te_avtab,&key);
  printf("allow %s hal_graphics_allocator_default:memfd_file { read write map getattr }; prior_bits=%08x added_bits=%08x\n",sources[i],old?old->data:0,bits&~(old?old->data:0));
  if(old)old->data|=bits;else {avtab_datum_t val={.data=bits};if(avtab_insert(&p.te_avtab,&key,&val))return 8;}
 }
 f.fp=fopen(argv[2],"wb");if(!f.fp)return 9;
 if(policydb_write(&p,&f)||fclose(f.fp))return 10;policydb_destroy(&p);return 0;
}
